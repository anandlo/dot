import Foundation
import XCTest

@testable import DotCore

/// The rewrite that happens between a transcript and the app it is typed into.
///
/// Every rule is stated per target and then held to two properties that matter
/// more than any single example: applying the rewrite twice is the same as
/// applying it once, and a long commit subject is reported rather than cut.
final class OutputGrammarTests: XCTestCase {
    private func apply(
        _ text: String,
        _ target: DictationTarget,
        options: OutputGrammar.Options = .default
    ) -> String {
        OutputGrammar.apply(text, target: target, options: options)
    }

    // MARK: - Every target

    func testEveryTargetCollapsesWhitespaceAndTrims() {
        for target in DictationTarget.allCases {
            XCTAssertEqual(
                apply("  hello   there  ", target),
                target == .document ? "Hello there." : "hello there",
                "\(target)"
            )
        }
    }

    func testEveryTargetRemovesASpaceBeforePunctuation() {
        for target in DictationTarget.allCases {
            let text = "Wait  , what ?"
            XCTAssertFalse(
                apply(text, target).contains(" ,"),
                "\(target) kept a space before a comma"
            )
            XCTAssertFalse(apply(text, target).contains(" ?"), "\(target) kept a space before a question mark")
        }
    }

    func testAnEmptyTranscriptStaysEmpty() {
        for target in DictationTarget.allCases {
            XCTAssertEqual(apply("", target), "", "\(target)")
            XCTAssertEqual(apply("   \n  ", target), "", "\(target)")
        }
    }

    // MARK: - Plain

    func testPlainKeepsTheWordsAndTheParagraphs() {
        let text = "First line.\n\nSecond line, unfinished"
        XCTAssertEqual(apply(text, .plain), text)
        // Plain does not add a full stop and does not capitalise.
        XCTAssertEqual(apply("lower case", .plain), "lower case")
    }

    // MARK: - Chat

    func testChatKeepsNewlinesAndDropsOneTrailingFullStop() {
        XCTAssertEqual(apply("Sounds good.", .chat), "Sounds good")
        XCTAssertEqual(apply("Sounds good..", .chat), "Sounds good..", "an ellipsis is a decision")
        XCTAssertEqual(
            apply("First thought.\nSecond thought.", .chat),
            "First thought.\nSecond thought.",
            "with more than one sentence the full stop belongs to the person"
        )
    }

    func testChatDropsTheFullStopOnlyOnASingleSentence() {
        XCTAssertEqual(apply("On my way!", .chat), "On my way!", "an exclamation is not a full stop")
        XCTAssertEqual(apply("Is it done?", .chat), "Is it done?")
        XCTAssertEqual(apply("One. Two", .chat), "One. Two")
    }

    // MARK: - Code

    func testCodeIsOneLineWithoutATrailingFullStop() {
        XCTAssertEqual(apply("The value\nis 42.", .code), "The value is 42")
        XCTAssertEqual(apply("guard let self else { return }.", .code), "guard let self else { return }")
        XCTAssertEqual(apply("git status --short.", .code), "git status --short")
    }

    func testCodeLeavesQuotesBracketsAndCasingAlone() {
        let text = "let s = \"Hello, World\" + (1 + 2)"
        XCTAssertEqual(apply(text, .code), text)

        // A full stop inside a string is not the end of a sentence.
        XCTAssertEqual(apply("print(\"done.\")", .code), "print(\"done.\")")
        // And a full stop after a closing bracket is the sentence's, not the
        // bracket's.
        XCTAssertEqual(apply("call().", .code), "call()")
    }

    // MARK: - Commit

    func testCommitIsOneLineWithoutATrailingFullStop() {
        XCTAssertEqual(apply("Add the retry loop.", .commit), "Add the retry loop")
        XCTAssertEqual(apply("Fix\nthe  parser.", .commit), "Fix the parser")
    }

    func testCommitNeverTruncatesALongSubject() {
        let long = "Add a bounded exponential update for the microphone calibration book "
            + "so an old room is replaced instead of remembered forever."
        let result = OutputGrammar.result(for: long, target: .commit)
        XCTAssertTrue(result.wasLong)
        // The only change is the trailing full stop the rule removes; nothing
        // is cut off the end.
        XCTAssertEqual(result.text, String(long.dropLast()))
        XCTAssertEqual(result.text.count, long.count - 1)
        for word in long.dropLast().split(separator: " ") {
            XCTAssertTrue(result.text.contains(word), "\(word) was lost")
        }
    }

    func testAShortCommitIsNotFlagged() {
        let result = OutputGrammar.result(for: "Fix the parser.", target: .commit)
        XCTAssertFalse(result.wasLong)
        XCTAssertEqual(result.text, "Fix the parser")
    }

    func testTheCommitLimitIsAnOption() {
        let text = "Fix the parser in the retry loop"
        XCTAssertTrue(
            OutputGrammar.result(for: text, target: .commit, options: OutputGrammar.Options(commitSubjectLimit: 10))
                .wasLong
        )
        XCTAssertFalse(
            OutputGrammar.result(for: text, target: .commit, options: OutputGrammar.Options(commitSubjectLimit: 200))
                .wasLong
        )
    }

    // MARK: - Document

    func testDocumentCapitalisesAndEndsInAFullStop() {
        XCTAssertEqual(apply("hello there", .document), "Hello there.")
        XCTAssertEqual(apply("hello there.", .document), "Hello there.")
        XCTAssertEqual(apply("already done!", .document), "Already done!")
        XCTAssertEqual(apply("\"quoted words\"", .document), "\"Quoted words\".")
    }

    func testDocumentKeepsParagraphsAndOpensEachOne() {
        XCTAssertEqual(
            apply("first paragraph\n\nsecond paragraph", .document),
            "First paragraph\n\nSecond paragraph."
        )
    }

    func testDocumentEndsAfterAClosingQuote() {
        XCTAssertEqual(apply("he said \"hello\"", .document), "He said \"hello\".")
    }

    // MARK: - Properties

    func testApplyingTheRewriteTwiceChangesNothing() {
        let samples = [
            "  hello   there  ",
            "First thought.\n\nSecond thought.",
            "One line\nand another.",
            "let x = 1.",
            "Add the retry loop.",
            "hello there",
            "Wait  , what ?",
            "An ellipsis...",
            "",
            "a\n\n\n\nb",
        ]
        for target in DictationTarget.allCases {
            for sample in samples {
                let once = apply(sample, target)
                let twice = apply(once, target)
                XCTAssertEqual(twice, once, "\(target) is not idempotent for \(sample.debugDescription)")
            }
        }
    }

    // MARK: - Target selection

    func testTheTableNamesTheCommonApps() {
        XCTAssertEqual(DictationTarget.resolved(bundleIdentifier: "com.tinyspeck.slackmacgap"), .chat)
        XCTAssertEqual(DictationTarget.resolved(bundleIdentifier: "com.hnc.Discord"), .chat)
        XCTAssertEqual(DictationTarget.resolved(bundleIdentifier: "com.apple.dt.Xcode"), .code)
        XCTAssertEqual(DictationTarget.resolved(bundleIdentifier: "com.microsoft.VSCode"), .code)
        XCTAssertEqual(DictationTarget.resolved(bundleIdentifier: "com.jetbrains.intellij"), .code)
        XCTAssertEqual(DictationTarget.resolved(bundleIdentifier: "com.googlecode.iterm2"), .code)
        XCTAssertEqual(DictationTarget.resolved(bundleIdentifier: "com.github.GitHubClient"), .commit)
        XCTAssertEqual(DictationTarget.resolved(bundleIdentifier: "com.apple.Notes"), .document)
        XCTAssertEqual(DictationTarget.resolved(bundleIdentifier: "com.apple.mail"), .document)
    }

    func testAnUnknownBundleIdentifierIsPlain() {
        XCTAssertEqual(DictationTarget.resolved(bundleIdentifier: "com.example.unknown"), .plain)
        XCTAssertEqual(DictationTarget.resolved(bundleIdentifier: "com.jetbrainsx.app"), .plain)
        XCTAssertEqual(DictationTarget.resolved(bundleIdentifier: nil), .plain)
        XCTAssertEqual(DictationTarget.resolved(bundleIdentifier: "   "), .plain)
        XCTAssertEqual(DictationTarget.resolved(bundleIdentifier: ""), .plain)
    }

    func testAnOverrideWinsOverTheTable() {
        let overrides = ["com.apple.dt.Xcode": DictationTarget.document]
        XCTAssertEqual(
            DictationTarget.resolved(bundleIdentifier: "com.apple.dt.Xcode", overrides: overrides),
            .document
        )
        // A bundle identifier Dot has never heard of can be added by hand.
        XCTAssertEqual(
            DictationTarget.resolved(bundleIdentifier: "com.example.app", overrides: ["com.example.app": .chat]),
            .chat
        )
    }

    func testAnOverrideForNoAppIsDropped() {
        XCTAssertTrue(DictationTarget.normalizedOverrides(["  ": .chat]).isEmpty)
        XCTAssertEqual(
            DictationTarget.normalizedOverrides([" com.example.app ": .code]),
            ["com.example.app": .code]
        )
    }

    func testTheConfigurationResolvesTheTargetOfAnApp() {
        var config = DotConfig.default
        config.outputGrammarTargets = ["com.example.app": .commit]
        XCTAssertEqual(config.dictationTarget(for: "com.example.app"), .commit)
        XCTAssertEqual(config.dictationTarget(for: "com.tinyspeck.slackmacgap"), .chat)
        XCTAssertEqual(config.dictationTarget(for: nil), .plain)
    }

    // MARK: - The boundary

    func testTheRewriteIsOffByDefault() {
        XCTAssertFalse(DotConfig.default.outputGrammarEnabled)
        XCTAssertTrue(DotConfig.default.outputGrammarTargets.isEmpty)
        XCTAssertNil(
            DotConfig.default.outputGrammarTargets["com.tinyspeck.slackmacgap"],
            "the table decides until the person says otherwise"
        )
    }

    func testTheConfigurationWithoutTheGrammarFieldsLoads() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dot-grammar-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try #"{"provider": "openai"}"#.write(to: url, atomically: true, encoding: .utf8)

        let loaded = DotConfig.load(from: url)
        XCTAssertFalse(loaded.outputGrammarEnabled)
        XCTAssertTrue(loaded.outputGrammarTargets.isEmpty)
    }

    func testTheGrammarFieldsRoundTrip() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dot-grammar-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        var config = DotConfig.default
        config.outputGrammarEnabled = true
        config.outputGrammarTargets = ["com.apple.dt.Xcode": .plain]
        try config.save(to: url)

        let loaded = DotConfig.load(from: url)
        XCTAssertTrue(loaded.outputGrammarEnabled)
        XCTAssertEqual(loaded.outputGrammarTargets, ["com.apple.dt.Xcode": .plain])
    }

    func testTheHistoryAndTheClipboardKeepTheOriginalWords() {
        let transcript = "Ship the palette on Thursday."
        let grammar = OutputGrammar.result(for: transcript, target: .commit)
        XCTAssertNotEqual(grammar.text, transcript, "the case has to exercise a change")

        let plan = TranscriptDelivery.plan(transcript: transcript, grammar: grammar)
        XCTAssertEqual(plan.insertion, "Ship the palette on Thursday")
        XCTAssertEqual(plan.clipboard, transcript, "the clipboard is never rewritten")

        // The same value the plan keeps is the one the history stores.
        let history = HistoryStore.adding(transcript, at: Date(), to: [])
        XCTAssertEqual(history.first?.text, plan.clipboard)
    }

    func testWithTheRewriteOffTheInsertionIsTheTranscript() {
        let transcript = "One line.\nAnd another."
        let plan = TranscriptDelivery.plan(transcript: transcript, grammar: nil)
        XCTAssertEqual(plan.insertion, transcript)
        XCTAssertEqual(plan.clipboard, transcript)
    }
}
