import DotCore
import Foundation
import XCTest

@testable import Dot

/// The assistant's turn, driven without a network, a Keychain or an island.
@MainActor
final class AssistantCoordinatorTests: XCTestCase {
    private let clock = TestClock()
    private var provider: ScriptedChatProvider!
    private var factory: FakeChatFactory!
    private let speaker = FakeSpeaker()
    private let paster = FakePaster()
    private let hud = FakeAssistantHUD()
    private var configuration = AssistantConfiguration.default
    private var speakerBuilds = 0

    /// The application a question was asked in.
    private let mail = FrontmostApp(processIdentifier: 42, bundleIdentifier: "com.apple.mail")

    private func makeCoordinator(
        events: [ChatEvent]? = nil,
        scripts: [[ChatEvent]]? = nil,
        hasKey: Bool = true,
        pace: ScriptedChatProvider.Pace = .instant
    ) -> AssistantCoordinator {
        provider = scripts.map { ScriptedChatProvider(scripts: $0, pace: pace) }
            ?? ScriptedChatProvider(events: events ?? [], pace: pace)
        factory = FakeChatFactory(provider: provider, hasKey: hasKey)
        let clock = self.clock
        let configuration = self.configuration
        let paster = self.paster
        let hud = self.hud
        return AssistantCoordinator(
            factory: factory,
            makeSpeaker: { [unowned self] in
                self.speakerBuilds += 1
                return self.speaker
            },
            paster: paster,
            hud: hud,
            settings: {
                AssistantRuntimeSettings(
                    configuration: configuration,
                    autoPaste: true,
                    ownBundleIdentifier: "com.example.dot"
                )
            },
            now: { clock.now }
        )
    }

    /// A turn that answers with one piece of text.
    private func answering(_ text: String) -> [ChatEvent] {
        [.textDelta(text), .done(.endTurn)]
    }

    /// Waits for a condition and fails with the event list when it never holds.
    private func expect(
        _ condition: @escaping () -> Bool,
        _ message: @autoclosure () -> String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let met = await waitUntil(condition)
        if !met {
            XCTFail("\(message()); events: \(hud.events)", file: file, line: line)
        }
    }

    func testNoKeyShowsTheSettingsMessageAndAsksNothing() async {
        let coordinator = makeCoordinator(events: answering("Hello."), hasKey: false)
        coordinator.ask("What is the weather?", frontmost: mail, frontmostName: "Mail")
        XCTAssertEqual(
            hud.events,
            [.message("Connect an assistant service in Settings.", "sparkle")]
        )
        XCTAssertEqual(provider.callCount, 0, "no request may be made without a key")
        XCTAssertEqual(factory.providerCallCount, 0)
        XCTAssertEqual(coordinator.createdComponents, 0)
        XCTAssertEqual(coordinator.phase, .idle)
    }

    func testALocalServiceNeedsNoKey() async {
        configuration.chat = AssistantSettings(providerID: "ollama", model: "llama3.2")
        let coordinator = makeCoordinator(events: answering("Hello."), hasKey: false)
        coordinator.ask("Are you there?", frontmost: mail)
        await expect({ self.hud.lastAnswerText == "Hello." }, "the answer never arrived")
        XCTAssertEqual(provider.callCount, 1)
    }

    func testNothingIsBuiltBeforeTheFirstQuestion() {
        let coordinator = makeCoordinator(events: answering("Hello."))
        XCTAssertEqual(coordinator.createdComponents, 0)
        XCTAssertEqual(factory.providerCallCount, 0)
        XCTAssertEqual(factory.toolCallCount, 0)
        XCTAssertEqual(speakerBuilds, 0)
    }

    func testTheFirstQuestionBuildsTheEngineOnce() async {
        let coordinator = makeCoordinator(events: answering("Hello."))
        coordinator.ask("One?", frontmost: mail)
        await expect({ self.hud.lastAnswerText == "Hello." }, "the answer never arrived")
        XCTAssertEqual(factory.providerCallCount, 1)
        XCTAssertEqual(factory.toolCallCount, 1)
        XCTAssertEqual(coordinator.createdComponents, 2, "the provider and the tools")
    }

    func testTheAnswerIsPastedWhenTheApplicationIsStillThere() async {
        paster.frontmostApp = mail
        paster.accessibilityGranted = true
        let coordinator = makeCoordinator(events: answering("Two things tomorrow."))
        coordinator.ask("What is on tomorrow?", frontmost: mail, frontmostName: "Mail")

        await expect({ self.hud.answers.contains(.pasted("Mail")) }, "the paste never landed")
        XCTAssertEqual(paster.copies, ["Two things tomorrow."])
        XCTAssertEqual(paster.pastes, 1)
        XCTAssertNil(hud.answers.last(where: { $0 == .copied }))
    }

    func testTheAnswerIsOnlyCopiedWhenTheApplicationChanged() async {
        paster.frontmostApp = FrontmostApp(processIdentifier: 99, bundleIdentifier: "com.apple.Safari")
        paster.accessibilityGranted = true
        let coordinator = makeCoordinator(events: answering("Two things tomorrow."))
        coordinator.ask("What is on tomorrow?", frontmost: mail, frontmostName: "Mail")

        await expect({ self.hud.answers.contains(.copied) }, "the copy never happened")
        XCTAssertEqual(paster.copies, ["Two things tomorrow."])
        XCTAssertEqual(paster.pastes, 0, "a paste would land in another application")
    }
}

extension AssistantCoordinatorTests {
    func testTheVoiceIsFedEveryDeltaInOrderAndThenFinished() async {
        configuration.delivery = .speak
        let coordinator = makeCoordinator(events: [
            .textDelta("You "),
            .textDelta("have "),
            .textDelta("two "),
            .textDelta("things."),
            .done(.endTurn),
        ])
        coordinator.ask("What is on tomorrow?", frontmost: mail)

        await expect({ self.speaker.feeds.count == 4 }, "not every delta reached the voice")
        XCTAssertEqual(speaker.feeds, ["You ", "have ", "two ", "things."])
        XCTAssertEqual(speaker.begins, 1)
        XCTAssertEqual(speaker.finishes, 1)
        await expect({ self.hud.answers.last == .speaking }, "the card never said it was speaking")
        XCTAssertEqual(paster.pastes, 0, "a spoken answer is not pasted")

        speaker.finishPlayback()
        await expect({ self.hud.answers.last == .spoken }, "playback never ended")
        XCTAssertEqual(speakerBuilds, 1)
    }

    func testADeclinedConfirmationRunsNothing() async {
        let call = ToolCall(id: "call-1", name: "reminders_create", arguments: .object([:]))
        let coordinator = makeCoordinator(scripts: [
            [.toolCall(call), .done(.toolCalls)],
            [.textDelta("I did not add it."), .done(.endTurn)],
        ])
        coordinator.ask("Remind me to call Sam.", frontmost: mail, frontmostName: "Mail")

        await expect({ self.hud.events.contains(.confirm("Add a reminder")) }, "no confirmation appeared")
        XCTAssertEqual(coordinator.phase, .confirming)
        coordinator.declineConfirmation()

        await expect(
            { self.factory.spy?.invokeCount == 0 && self.hud.lastAnswerText == "I did not add it." },
            "the turn did not continue after the decline"
        )
        XCTAssertEqual(factory.spy?.invokeCount, 0, "a declined call must never reach the connector")
        XCTAssertTrue(hud.events.contains(.hideConfirm))
    }

    func testCancellingMidStreamEndsTheStreamAtOnce() async {
        let deltas = (0..<40).map { ChatEvent.textDelta("word\($0) ") }
        let coordinator = makeCoordinator(
            events: deltas + [.done(.endTurn)],
            pace: .paced(25)
        )
        coordinator.ask("Tell me a long story.", frontmost: mail)
        await expect({ coordinator.phase == .streaming }, "the answer never started streaming")

        let started = Date()
        coordinator.cancelTurn()
        let ended = await waitUntil(timeout: 0.2) { self.provider.lastTermination != nil }
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertTrue(ended, "the stream was still open 200 ms after the cancel")
        XCTAssertLessThan(elapsed, 0.2)
        XCTAssertEqual(coordinator.phase, .idle)
        XCTAssertEqual(hud.events.last, .hide)
    }

    func testTheConversationIsCarriedForTwoMinutesAndThenDropped() async {
        let coordinator = makeCoordinator(events: answering("First."))
        coordinator.ask("First question", frontmost: mail)
        await expect({ self.provider.callCount == 1 && self.hud.lastAnswerText == "First." }, "the first answer never arrived")

        clock.advance(60)
        coordinator.ask("Second question", frontmost: mail)
        await expect({ self.provider.callCount == 2 }, "the second question was never sent")
        let second = provider.conversations[1]
        XCTAssertTrue(
            second.contains { $0.role == .user && $0.text == "First question" },
            "a conversation inside two minutes carries the earlier question"
        )
        XCTAssertTrue(second.contains { $0.role == .assistant && $0.text == "First." })

        clock.advance(122)
        coordinator.ask("Third question", frontmost: mail)
        await expect({ self.provider.callCount == 3 }, "the third question was never sent")
        let third = provider.conversations[2]
        XCTAssertFalse(
            third.contains { $0.role == .assistant },
            "a conversation older than two minutes is a new one"
        )
        XCTAssertFalse(third.contains { $0.text == "First question" })
    }

    func testAFailureDropsTheConversation() async {
        let coordinator = makeCoordinator(scripts: [
            [.textDelta("Hello."), .done(.endTurn)],
            [.done(.endTurn)],
        ])
        coordinator.ask("One?", frontmost: mail)
        await expect({ self.hud.lastAnswerText == "Hello." }, "the first answer never arrived")
        coordinator.ask("Two?", frontmost: mail)
        await expect({ self.provider.callCount == 2 }, "the second question was never sent")
        // The second turn had no text, so the conversation is not worth keeping.
        await expect(
            { self.hud.events.contains(.message("The assistant did not answer.", "sparkle")) },
            "an empty answer did not say so"
        )
        coordinator.ask("Three?", frontmost: mail)
        await expect({ self.provider.callCount == 3 }, "the third question was never sent")
        XCTAssertFalse(provider.conversations[2].contains { $0.role == .assistant })
    }
}
