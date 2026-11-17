import XCTest

@testable import DotCore

/// The rewrite prompts ask for nothing the speaker did not say, and the block
/// Dot adds under an Agent prompt is Dot's own text.
///
/// The phrases checked here are the ones the retired Agent prompt used to ask
/// for: a line per detail the task was missing, a section of open questions and
/// a list of working rules the model assembled for itself. None of them may
/// reach a model through a shipped template, through the sentences Dot wraps
/// around every template, or through the sentence a custom style carries.
final class RewriteNoAdditionsTests: XCTestCase {
    /// Every phrase that asked the model to name, or to supply, what was not said.
    private static let retiredPhrases = [
        "[missing",
        "Include the relevant",
        "drawing from",
        "If none were said",
        "Open questions",
        "Working rules",
    ]

    func testNoTemplateAsksForWhatTheSpeakerDidNotSay() {
        for id in RewriteStyleID.allCases {
            let template = id.template
            for phrase in Self.retiredPhrases {
                XCTAssertFalse(
                    template.contains(phrase),
                    "\(id.rawValue) still asks for: \(phrase)"
                )
            }
        }
    }

    func testTheSharedSentencesAskForNothing() {
        let shared = [
            RewritePrompt.transcriptionCleanupInstruction,
            RewritePrompt.dataSentence,
            CustomRewriteStyle.suffix,
        ]
        for sentence in shared {
            for phrase in Self.retiredPhrases {
                XCTAssertFalse(
                    sentence.contains(phrase),
                    "a shared sentence still asks for: \(phrase)"
                )
            }
        }
    }

    /// Every shipped template forbids adding to what the speaker said.
    ///
    /// `shippedCases` rather than `allCases`: Plain English is retired and
    /// reaches a model only through a file written before the consolidation,
    /// and its own sentence forbids examples rather than content in the two
    /// words this checks. Its wording is left as it shipped.
    func testEveryShippedTemplateForbidsAdditions() {
        for id in RewriteStyleID.shippedCases {
            let template = id.template
            XCTAssertTrue(
                template.contains("Do not add") || template.contains("Add nothing"),
                "\(id.rawValue) does not forbid adding content"
            )
        }
    }

    /// The Agent prompt is the one template that builds sections, and it says
    /// which of them may be drawn and what may fill them.
    func testTheAgentPromptDrawsOnlySectionsTheSpeakerFilled() {
        let template = RewriteStyleID.prompt.template
        for phrase in [
            "Add nothing the speaker did not say",
            "Goal is always present",
            "Every other section appears only when the speaker said something for it",
            "never write a section to say it is empty",
            "only as stated",
            "The checks the speaker named for knowing the task is complete",
        ] {
            XCTAssertTrue(template.contains(phrase), "the Agent prompt lost: \(phrase)")
        }
        XCTAssertEqual(
            template.components(separatedBy: "## ").count - 1,
            5,
            "the Agent prompt asks for a number of sections it does not describe"
        )
    }
}

extension RewriteNoAdditionsTests {
    // MARK: - The standing rules Dot appends

    /// A configuration with the block on and one line of text.
    private func configuration(rules: String?, enabled: Bool = true) -> RewriteConfiguration {
        var configuration = RewriteConfiguration.default
        configuration.standingRulesEnabled = enabled
        if let rules { configuration.setStandingRules(rules) }
        return configuration
    }

    /// The delivered text is the answer, one blank line, then the block.
    func testTheStandingRulesSitUnderTheAnswer() {
        let rules = "## House rules\n- Run the build and the tests.\n- Never touch main."
        let configuration = self.configuration(rules: rules)
        XCTAssertEqual(configuration.standingRulesText, rules)
        let output = "## Goal\nShip the settings card."
        XCTAssertEqual(
            RewritePrompt.delivered(output, standingRules: configuration.standingRulesText),
            output + "\n\n" + rules
        )
        // The block is the person's own lines: nothing rewraps or trims it.
        let stored = "  - indented line  \n- second line\n"
        let verbatim = self.configuration(rules: stored)
        XCTAssertEqual(
            RewritePrompt.delivered("Answer.", standingRules: verbatim.standingRulesText),
            "Answer.\n\n" + stored
        )
    }

    /// Off, or on with nothing written, leaves the answer as it is.
    func testTheBlockIsLeftOutWhenItIsOffOrBlank() {
        for configuration in [
            self.configuration(rules: "- One.", enabled: false),
            self.configuration(rules: nil),
            self.configuration(rules: ""),
            self.configuration(rules: "   \n\t "),
        ] {
            XCTAssertNil(configuration.standingRulesText)
            XCTAssertEqual(
                RewritePrompt.delivered("Answer.", standingRules: configuration.standingRulesText),
                "Answer."
            )
        }
    }

    /// The length check has to read the answer, not the answer with the block.
    ///
    /// The premise is measured: the same answer passes the Agent prompt's band
    /// and the delivered text, which carries the block, falls outside it. A
    /// pipeline that measured the delivered text would report every faithful
    /// answer as a rewrite that changed its length.
    func testTheLengthCheckReadsTheAnswerWithoutTheBlock() {
        let original = String(repeating: "Ship the build to the staging server tonight. ", count: 3)
        let answer = original
        let rules = String(repeating: "Standing rule line. ", count: 20)
        let style = RewriteStyle(.prompt)

        let onTheAnswer = FaithfulnessCheck.check(original: original, rewrite: answer, style: style)
        XCTAssertTrue(onTheAnswer.isFaithful, "the premise: the answer alone is faithful")

        let delivered = RewritePrompt.delivered(answer, standingRules: rules)
        XCTAssertGreaterThan(Double(delivered.count), Double(original.count) * 3)
        XCTAssertLessThanOrEqual(Double(answer.count), Double(original.count) * 3)
        let onTheDeliveredText = FaithfulnessCheck.check(
            original: original,
            rewrite: delivered,
            style: style
        )
        XCTAssertEqual(
            onTheDeliveredText.warnings,
            [FaithfulnessCheck.lengthChanged],
            "the premise: counting the block breaks the length band"
        )
    }

    /// The block is held to the length the settings keep.
    func testTheStandingRulesAreCappedAtTwoThousandCharacters() {
        XCTAssertEqual(RewriteConfiguration.maximumStandingRulesLength, 2_000)
        let configuration = self.configuration(rules: String(repeating: "a", count: 2_500))
        XCTAssertEqual(configuration.standingRules.count, 2_000)
        var direct = RewriteConfiguration.default
        direct.setStandingRules(String(repeating: "b", count: 2_500))
        XCTAssertEqual(direct.standingRules.count, 2_000)
        let built = RewriteConfiguration(standingRules: String(repeating: "c", count: 2_500))
        XCTAssertEqual(built.standingRules.count, 2_000)
    }

    /// A fresh configuration carries no block, and the Agent prompt is the only
    /// style whose delivery could ever carry one.
    func testTheBlockIsOffInAFreshConfiguration() {
        let configuration = RewriteConfiguration.default
        XCTAssertFalse(configuration.standingRulesEnabled)
        XCTAssertEqual(configuration.standingRules, "")
        XCTAssertNil(configuration.standingRulesText)
    }
}
