import ApplicationServices
import Foundation
import XCTest
@testable import Dot
import DotCore

/// The delivery chain from a saved configuration and the app at the press to
/// the two strings the delivery uses: what is pasted and what is remembered.
final class PerAppFormatDeliveryTests: XCTestCase {
    private let transcript = "ship the  login fix .\nAnd update  the tests and the release notes before the  friday  demo."

    private let tableApps: [(id: String, target: DictationTarget)] = [
        ("com.tinyspeck.slackmacgap", .chat),
        ("com.apple.dt.Xcode", .code),
        ("com.github.GitHubClient", .commit),
        ("com.apple.Notes", .document),
    ]

    private let chatInsertion = "ship the login fix.\nAnd update the tests and the release notes before the friday demo."
    private let codeInsertion = "ship the login fix. And update the tests and the release notes before the friday demo"
    private let documentInsertion = "Ship the login fix.\nAnd update the tests and the release notes before the friday demo."

    /// Writes a real config file and reads the config the delivery seam will
    /// use, so a field that fails either way cannot pass these tests.
    private func loadedConfig(
        enabled: Bool,
        overrides: [String: DictationTarget] = [:],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> DotConfig {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dot-per-app-format-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var config = DotConfig.default
        config.outputGrammarEnabled = enabled
        config.outputGrammarTargets = overrides
        let url = directory.appendingPathComponent("config.json")
        do {
            try config.save(to: url)
        } catch {
            XCTFail("config.save failed: \(error)", file: file, line: line)
            throw error
        }
        return DotConfig.load(from: url)
    }

    func testFormattingOffInsertsTheTranscriptForEveryApp() throws {
        let bundleIDs = tableApps.map(\.id) + ["com.example.unknown"]
        for bundleID in bundleIDs {
            let config = try loadedConfig(enabled: false)
            let delivery = perAppFormatDelivery(
                for: transcript,
                config: config,
                frontmostBundleIdentifier: bundleID
            )
            XCTAssertNil(delivery.grammar, "\(bundleID)")
            XCTAssertEqual(delivery.plan.insertion, transcript, "\(bundleID)")
            XCTAssertEqual(delivery.plan.clipboard, transcript, "\(bundleID)")
        }
    }

    func testTableTargetsSelectTheExactInsertionForEachApp() throws {
        var grammars: [DictationTarget: OutputGrammar.Result] = [:]
        for app in tableApps {
            let config = try loadedConfig(enabled: true)
            let delivery = perAppFormatDelivery(
                for: transcript,
                config: config,
                frontmostBundleIdentifier: app.id
            )
            let expected: String
            switch app.target {
            case .chat: expected = chatInsertion
            case .code, .commit: expected = codeInsertion
            case .document: expected = documentInsertion
            case .plain:
                XCTFail("the table apps must name a rewrite target")
                continue
            }
            XCTAssertEqual(delivery.grammar?.target, app.target, "\(app.id)")
            XCTAssertEqual(delivery.plan.insertion, expected, "\(app.id)")
            XCTAssertEqual(delivery.plan.clipboard, transcript, "\(app.id)")
            guard let grammar = delivery.grammar else {
                XCTFail("\(app.id) has no grammar", file: #filePath, line: #line)
                continue
            }
            grammars[app.target] = grammar
        }
        // Under the shipped rules a commit subject gets the same text as code;
        // its distinct output is the long-subject flag on the result.
        XCTAssertEqual(grammars[.code]?.text, grammars[.commit]?.text)
        XCTAssertEqual(grammars[.code]?.wasLong, false)
        XCTAssertEqual(grammars[.commit]?.wasLong, true)
    }

    func testOverrideWinsOverTheTableTargetForTheSameApp() throws {
        let bundleID = "com.apple.dt.Xcode"
        let config = try loadedConfig(enabled: true, overrides: [bundleID: .document])
        let delivery = perAppFormatDelivery(
            for: transcript,
            config: config,
            frontmostBundleIdentifier: bundleID
        )
        XCTAssertEqual(delivery.grammar?.target, .document)
        XCTAssertEqual(delivery.plan.insertion, documentInsertion)
        XCTAssertNotEqual(delivery.plan.insertion, codeInsertion)
        XCTAssertEqual(delivery.plan.clipboard, transcript)
    }

    func testUnknownAppIsPlainAndInsertsTheTranscript() throws {
        let config = try loadedConfig(enabled: true)
        XCTAssertEqual(config.dictationTarget(for: "com.example.unknown"), .plain)
        let delivery = perAppFormatDelivery(
            for: transcript,
            config: config,
            frontmostBundleIdentifier: "com.example.unknown"
        )
        XCTAssertNil(delivery.grammar)
        XCTAssertEqual(delivery.plan.insertion, transcript)
        XCTAssertEqual(delivery.plan.clipboard, transcript)
    }

    func testHistoryAndClipboardKeepTheOriginalWordsInEveryCase() throws {
        var plans: [TranscriptDelivery] = []
        for app in tableApps {
            let configured = try loadedConfig(
                enabled: true,
                overrides: app.target == .code ? [app.id: .document] : [:]
            )
            plans.append(perAppFormatDelivery(
                for: transcript,
                config: configured,
                frontmostBundleIdentifier: app.id
            ).plan)
        }
        let disabled = try loadedConfig(enabled: false)
        plans.append(perAppFormatDelivery(
            for: transcript,
            config: disabled,
            frontmostBundleIdentifier: "com.tinyspeck.slackmacgap"
        ).plan)
        let unknown = try loadedConfig(enabled: true)
        plans.append(perAppFormatDelivery(
            for: transcript,
            config: unknown,
            frontmostBundleIdentifier: "com.example.unknown"
        ).plan)

        XCTAssertEqual(plans.count, 6)
        for plan in plans {
            XCTAssertEqual(plan.clipboard, transcript)
            let history = HistoryStore.adding(plan.clipboard, at: Date(), to: [])
            XCTAssertEqual(history.first?.text, transcript)
        }
    }

    func testSettingsStyleEntryReadsBackThroughTheDeliverySeam() throws {
        let bundleID = "com.apple.Notes"
        var config = DotConfig.default
        config.outputGrammarEnabled = true
        // The two writes the view makes when a person adds an app and picks a
        // style: seed it with today's resolved target, then set the new style.
        config.outputGrammarTargets[bundleID] = config.dictationTarget(for: bundleID)
        config.outputGrammarTargets[bundleID] = .code
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dot-per-app-format-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("config.json")
        try config.save(to: url)

        let loaded = DotConfig.load(from: url)
        XCTAssertEqual(loaded.outputGrammarTargets[bundleID], .code)
        let delivery = perAppFormatDelivery(
            for: transcript,
            config: loaded,
            frontmostBundleIdentifier: bundleID
        )
        XCTAssertEqual(delivery.grammar?.target, .code)
        XCTAssertEqual(delivery.plan.insertion, codeInsertion)
        XCTAssertEqual(delivery.plan.clipboard, transcript)
    }

    private func app(_ bundleID: String, processIdentifier: Int32 = 42) -> FrontmostApp {
        FrontmostApp(processIdentifier: processIdentifier, bundleIdentifier: bundleID)
    }

    private func dispatched(
        transcript: String,
        config: DotConfig,
        atPress: FrontmostApp,
        atDelivery: FrontmostApp,
        recorder: PasteboardRecorder,
        shouldCaptureAnchor: Bool = true,
        anchor: InsertionAnchor? = nil
    ) -> DispatchedTranscript {
        dispatchTranscript(
            transcript: transcript,
            config: config,
            atPress: atPress,
            atDelivery: { atDelivery },
            accessibilityGranted: { true },
            ownBundleIdentifier: "com.example.dot",
            shouldCaptureAnchor: { shouldCaptureAnchor },
            captureAnchor: { text in
                recorder.anchorCaptures.append(text)
                recorder.events.append("captureAnchor:\(text)")
                return anchor
            },
            pasteboard: recorder.pasteboard
        )
    }

    private func sentinelAnchor(for text: String) -> InsertionAnchor {
        InsertionAnchor(
            record: InsertionRecord(
                processIdentifier: 42,
                bundleIdentifier: "com.tinyspeck.slackmacgap",
                location: 7,
                length: text.utf16.count,
                insertedText: text,
                capturedAt: Date(timeIntervalSince1970: 0)
            ),
            field: FocusedTextField(
                processIdentifier: 42,
                bundleIdentifier: "com.tinyspeck.slackmacgap",
                element: AXUIElementCreateSystemWide(),
                selection: NSRange(location: 7, length: 0),
                isSecure: false
            )
        )
    }

    func testDispatchPastesTheFormattedInsertionAndRestoresTheOriginalClipboard() throws {
        let config = try loadedConfig(enabled: true)
        let recorder = PasteboardRecorder()
        let pressed = app("com.tinyspeck.slackmacgap")
        let result = dispatched(
            transcript: transcript,
            config: config,
            atPress: pressed,
            atDelivery: pressed,
            recorder: recorder
        )

        XCTAssertEqual(result.decision, .paste)
        XCTAssertEqual(result.delivery, .pasted)
        XCTAssertEqual(result.grammar?.target, .chat)
        XCTAssertEqual(result.plan.insertion, chatInsertion)
        XCTAssertEqual(result.plan.clipboard, transcript)
        XCTAssertEqual(recorder.copies, [transcript, chatInsertion])
        XCTAssertEqual(recorder.pasteCommands, 1)
        XCTAssertEqual(recorder.pastedText, chatInsertion, "the keystroke must carry the rewrite")
        XCTAssertEqual(recorder.anchorCaptures, [chatInsertion])
        XCTAssertEqual(recorder.copies.last, chatInsertion, "the rewrite stays on the pasteboard through Cmd-V")
        XCTAssertNil(recorder.restoredClipboard, "the original returns only after the target has read the paste")
        XCTAssertEqual(recorder.scheduledRestores.count, 1)
        XCTAssertEqual(recorder.scheduledRestores.first?.0, transcript)
        XCTAssertEqual(recorder.scheduledRestores.first?.1, chatInsertion)
        recorder.runDeferredRestore()
        XCTAssertEqual(recorder.restoredClipboard, transcript)
        XCTAssertEqual(recorder.finalClipboard, transcript)
        XCTAssertEqual(HistoryStore.adding(result.plan.clipboard, at: Date(), to: []).first?.text, transcript)
    }

    func testDispatchCopiesTheOriginalWhenTheFrontmostAppChanges() throws {
        let config = try loadedConfig(enabled: true)
        let recorder = PasteboardRecorder()
        let result = dispatched(
            transcript: transcript,
            config: config,
            atPress: app("com.tinyspeck.slackmacgap"),
            atDelivery: app("com.apple.dt.Xcode", processIdentifier: 99),
            recorder: recorder
        )

        XCTAssertEqual(result.decision, .copy(.applicationChanged))
        XCTAssertEqual(result.delivery, .copied)
        XCTAssertEqual(recorder.copies, [transcript])
        XCTAssertEqual(recorder.pasteCommands, 0)
        XCTAssertNil(recorder.pastedText)
        XCTAssertTrue(recorder.scheduledRestores.isEmpty)
        XCTAssertNil(recorder.restoredClipboard)
        XCTAssertEqual(recorder.finalClipboard, transcript)
    }

    func testDispatchPastesTheSameAppOverrideIntoTheFinalInsertion() throws {
        let bundleID = "com.apple.dt.Xcode"
        let config = try loadedConfig(enabled: true, overrides: [bundleID: .document])
        let recorder = PasteboardRecorder()
        let pressed = app(bundleID)
        let result = dispatched(
            transcript: transcript,
            config: config,
            atPress: pressed,
            atDelivery: pressed,
            recorder: recorder
        )

        XCTAssertEqual(result.decision, .paste)
        XCTAssertEqual(result.grammar?.target, .document)
        XCTAssertEqual(result.plan.insertion, documentInsertion)
        XCTAssertEqual(recorder.pastedText, documentInsertion)
        XCTAssertEqual(recorder.copies, [transcript, documentInsertion])
        XCTAssertNil(recorder.restoredClipboard)
        XCTAssertEqual(recorder.scheduledRestores.count, 1)
        XCTAssertEqual(recorder.scheduledRestores.first?.0, transcript)
        XCTAssertEqual(recorder.scheduledRestores.first?.1, documentInsertion)
        recorder.runDeferredRestore()
        XCTAssertEqual(recorder.restoredClipboard, transcript)
        XCTAssertEqual(recorder.finalClipboard, transcript)
    }

    func testFailedPasteRecopiesTheOriginalAndSchedulesNoRestore() throws {
        let config = try loadedConfig(enabled: true)
        let recorder = PasteboardRecorder()
        recorder.pasteSucceeds = false
        let pressed = app("com.tinyspeck.slackmacgap")
        let result = dispatched(
            transcript: transcript,
            config: config,
            atPress: pressed,
            atDelivery: pressed,
            recorder: recorder,
            anchor: sentinelAnchor(for: chatInsertion)
        )

        XCTAssertEqual(result.decision, .paste)
        XCTAssertEqual(result.delivery, .copied)
        XCTAssertNil(result.anchor)
        XCTAssertEqual(recorder.copies, [transcript, chatInsertion, transcript])
        XCTAssertEqual(recorder.pasteCommands, 1)
        XCTAssertNil(recorder.pastedText)
        XCTAssertEqual(recorder.anchorCaptures, [chatInsertion])
        XCTAssertTrue(recorder.scheduledRestores.isEmpty)
        XCTAssertNil(recorder.restoredClipboard)
        XCTAssertEqual(recorder.finalClipboard, transcript)
        let captureIndex = try XCTUnwrap(recorder.events.firstIndex { $0.hasPrefix("captureAnchor:") })
        let pasteIndex = try XCTUnwrap(recorder.events.firstIndex { $0.hasPrefix("pasteCommand:") })
        XCTAssertLessThan(captureIndex, pasteIndex)
        XCTAssertEqual(recorder.events[pasteIndex], "pasteCommand:failed")
    }

    func testUnformattedInsertionPastesTheOriginalOnceWithoutRestore() throws {
        var cases: [(String, DotConfig)] = []
        cases.append(("formatting off", try loadedConfig(enabled: false)))
        cases.append((
            "plain override",
            try loadedConfig(enabled: true, overrides: ["com.apple.dt.Xcode": .plain])
        ))

        for (name, config) in cases {
            let recorder = PasteboardRecorder()
            let pressed = app("com.apple.dt.Xcode")
            let result = dispatched(
                transcript: transcript,
                config: config,
                atPress: pressed,
                atDelivery: pressed,
                recorder: recorder
            )

            XCTAssertNil(result.grammar, name)
            XCTAssertEqual(result.plan.insertion, transcript, name)
            XCTAssertEqual(result.decision, .paste, name)
            XCTAssertEqual(result.delivery, .pasted, name)
            XCTAssertEqual(recorder.copies, [transcript], name)
            XCTAssertEqual(recorder.pasteCommands, 1, name)
            XCTAssertEqual(recorder.pastedText, transcript, name)
            XCTAssertTrue(recorder.scheduledRestores.isEmpty, name)
            XCTAssertNil(recorder.restoredClipboard, name)
            XCTAssertEqual(recorder.finalClipboard, transcript, name)
        }
    }

    func testAnchorCapturePrecedesPasteCommandAndReturnsTheCapturedAnchor() throws {
        let config = try loadedConfig(enabled: true)
        let recorder = PasteboardRecorder()
        let sentinel = sentinelAnchor(for: chatInsertion)
        let pressed = app("com.tinyspeck.slackmacgap")
        let result = dispatched(
            transcript: transcript,
            config: config,
            atPress: pressed,
            atDelivery: pressed,
            recorder: recorder,
            anchor: sentinel
        )

        XCTAssertEqual(result.delivery, .pasted)
        XCTAssertEqual(result.anchor?.record, sentinel.record)
        XCTAssertEqual(result.anchor?.record.insertedText, chatInsertion)
        XCTAssertEqual(recorder.anchorCaptures, [chatInsertion])
        let captureIndex = try XCTUnwrap(recorder.events.firstIndex { $0.hasPrefix("captureAnchor:") })
        let pasteIndex = try XCTUnwrap(recorder.events.firstIndex { $0.hasPrefix("pasteCommand:") })
        XCTAssertLessThan(captureIndex, pasteIndex)
        XCTAssertEqual(recorder.events[pasteIndex], "pasteCommand:ok")
        XCTAssertEqual(recorder.events, [
            "copy:\(transcript)",
            "copy:\(chatInsertion)",
            "captureAnchor:\(chatInsertion)",
            "pasteCommand:ok",
            "restoreScheduled:\(transcript)|\(chatInsertion)",
        ])
    }

    func testDisabledAnchorCaptureDoesNotCallTheAnchorProvider() throws {
        let config = try loadedConfig(enabled: true)
        let recorder = PasteboardRecorder()
        let pressed = app("com.tinyspeck.slackmacgap")
        let result = dispatched(
            transcript: transcript,
            config: config,
            atPress: pressed,
            atDelivery: pressed,
            recorder: recorder,
            shouldCaptureAnchor: false,
            anchor: sentinelAnchor(for: chatInsertion)
        )

        XCTAssertEqual(result.delivery, .pasted)
        XCTAssertNil(result.anchor)
        XCTAssertEqual(recorder.pastedText, chatInsertion)
        XCTAssertTrue(recorder.anchorCaptures.isEmpty)
        XCTAssertFalse(recorder.events.contains { $0.hasPrefix("captureAnchor:") })
    }

    @MainActor
    func testDispatchTranscriptAsyncCancelledDuringAnchorCaptureSkipsPasteAndRestoresClipboard() async throws {
        let config = try loadedConfig(enabled: true)
        let recorder = PasteboardRecorder()
        let pressed = app("com.tinyspeck.slackmacgap")
        var result: DispatchedTranscript?
        var deliveryTask: Task<Void, Never>?

        deliveryTask = Task { @MainActor in
            result = await dispatchTranscriptAsync(
                transcript: transcript,
                config: config,
                atPress: pressed,
                atDelivery: { pressed },
                accessibilityGranted: { true },
                ownBundleIdentifier: "com.example.dot",
                shouldCaptureAnchor: { true },
                captureAnchor: { text in
                    recorder.anchorCaptures.append(text)
                    deliveryTask?.cancel()
                    return nil
                },
                copy: { text in recorder.pasteboard.copy(text) },
                pasteCommand: { recorder.pasteboard.pasteCommand() },
                restore: { text, insertion in recorder.pasteboard.restore(text, insertion) }
            )
        }

        await deliveryTask?.value
        let dispatched = try XCTUnwrap(result)
        XCTAssertEqual(dispatched.delivery, .copied)
        XCTAssertNil(dispatched.anchor)
        XCTAssertEqual(recorder.pasteCommands, 0, "cancelled delivery must not post Cmd+V")
        XCTAssertEqual(recorder.finalClipboard, transcript, "rewritten clipboard must restore raw transcript on cancel")
        XCTAssertEqual(recorder.anchorCaptures, [chatInsertion])
    }
}

private final class PasteboardRecorder {
    var copies: [String] = []
    var pasteCommands = 0
    var pasteSucceeds = true
    var pastedText: String?
    var scheduledRestores: [(String, String)] = []
    var restoredClipboard: String?
    var anchorCaptures: [String] = []
    var events: [String] = []

    var pasteboard: DeliveryPasteboard {
        DeliveryPasteboard(
            copy: { [weak self] text in
                guard let self else { return }
                self.copies.append(text)
                self.events.append("copy:\(text)")
            },
            pasteCommand: { [weak self] in
                guard let self else { return false }
                self.pasteCommands += 1
                self.events.append(self.pasteSucceeds ? "pasteCommand:ok" : "pasteCommand:failed")
                if self.pasteSucceeds {
                    self.pastedText = self.copies.last
                }
                return self.pasteSucceeds
            },
            restore: { [weak self] text, insertion in
                guard let self else { return }
                self.scheduledRestores.append((text, insertion))
                self.events.append("restoreScheduled:\(text)|\(insertion)")
            }
        )
    }

    func runDeferredRestore() {
        guard let scheduled = scheduledRestores.last, copies.last == scheduled.1 else { return }
        restoredClipboard = scheduled.0
        copies.append(scheduled.0)
        events.append("restoreApplied:\(scheduled.0)")
    }

    var finalClipboard: String? {
        restoredClipboard ?? copies.last
    }
}
