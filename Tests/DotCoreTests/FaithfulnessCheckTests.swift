import XCTest

@testable import DotCore

/// The check that a rewrite still says what the transcript said.
///
/// Every rule is tested both ways: what it catches and what it must leave
/// alone. The second half matters as much as the first, because a check that
/// cries wolf teaches people to click through the card.
final class FaithfulnessCheckTests: XCTestCase {
    private let original = """
    Send the report to Priya by 5 pm on Thursday, and don't forget the appendix.
    """

    private func check(
        _ rewrite: String,
        from text: String? = nil,
        style: RewriteStyle = .formal
    ) -> FaithfulnessReport {
        FaithfulnessCheck.check(
            original: text ?? original,
            rewrite: rewrite,
            style: style
        )
    }

    // MARK: - Faithful

    func testAFaithfulRewriteReportsNothing() {
        let report = check("Send Priya the report by 5 pm on Thursday and don't forget the appendix.")
        XCTAssertTrue(report.errors.isEmpty, "\(report.errors)")
        XCTAssertTrue(report.warnings.isEmpty, "\(report.warnings)")
        XCTAssertTrue(report.isFaithful)
        XCTAssertFalse(report.blocksApply)
    }

    func testAWarningDoesNotBlockTheApply() {
        let report = check("Send the report by 5 pm on Thursday and don't forget the appendix.")
        XCTAssertTrue(report.errors.isEmpty)
        XCTAssertTrue(report.warnings.contains(FaithfulnessCheck.nameChanged))
        XCTAssertFalse(report.blocksApply)
        XCTAssertFalse(report.isFaithful)
    }

    func testADigitMayBecomeItsEnglishWordWithoutAWarning() {
        let report = check(
            "Send Priya the report by five pm on Thursday and don't forget the appendix."
        )
        XCTAssertTrue(report.errors.isEmpty, "\(report.errors)")
        XCTAssertTrue(report.warnings.isEmpty, "\(report.warnings)")
    }

    // MARK: - Numbers

    func testAChangedNumberIsAnError() {
        let report = check("Send Priya the report by 6 pm on Thursday and don't forget the appendix.")
        XCTAssertTrue(report.errors.contains(FaithfulnessCheck.numberChanged))
        XCTAssertTrue(report.blocksApply)
    }

    func testADroppedNumberIsAnError() {
        let report = check("Send Priya the report on Thursday and don't forget the appendix.")
        XCTAssertTrue(report.errors.contains(FaithfulnessCheck.numberChanged))
    }

    func testAThousandSeparatorIsTheSameNumber() {
        let report = check(
            "The budget of 1000 is approved.",
            from: "The budget of 1,000 is approved.",
            style: .formal
        )
        XCTAssertFalse(report.errors.contains(FaithfulnessCheck.numberChanged))
    }

    func testAThousandSeparatorInTheRewriteIsTheSameNumber() {
        let report = check(
            "The budget of 1,000 is approved.",
            from: "The budget of 1000 is approved.",
            style: .formal
        )
        XCTAssertFalse(report.errors.contains(FaithfulnessCheck.numberChanged))
    }

    func testADecimalIsKeptWhole() {
        let original = "The latency is 3.5 seconds."
        XCTAssertTrue(check("The latency is 35 seconds.", from: original)
            .errors.contains(FaithfulnessCheck.numberChanged))
        XCTAssertFalse(check("The latency is 3.5 seconds.", from: original)
            .errors.contains(FaithfulnessCheck.numberChanged))
    }

    func testADigitMayBecomeItsEnglishWordUpToTwenty() {
        let report = check("Three files are open.", from: "3 files are open.")
        XCTAssertFalse(report.errors.contains(FaithfulnessCheck.numberChanged))
    }

    func testAnEnglishWordAboveTwentyIsNotAccepted() {
        let report = check("Twenty one files are open.", from: "21 files are open.")
        XCTAssertTrue(report.errors.contains(FaithfulnessCheck.numberChanged))
    }

    func testTwentyItselfIsAcceptedAsAWord() {
        let report = check("Twenty files are open.", from: "20 files are open.")
        XCTAssertFalse(report.errors.contains(FaithfulnessCheck.numberChanged))
    }
}

extension FaithfulnessCheckTests {
    // MARK: - Negations

    func testADroppedNegationIsAnError() {
        let report = check("Send Priya the report by 5 pm on Thursday and forget the appendix.")
        XCTAssertTrue(report.errors.contains(FaithfulnessCheck.negationDropped))
        XCTAssertTrue(report.blocksApply)
    }

    func testAContractionCountsAsANegation() {
        let original = "The build doesn't pass yet."
        XCTAssertTrue(check("The build passes yet.", from: original)
            .errors.contains(FaithfulnessCheck.negationDropped))
        XCTAssertFalse(check("The build does not pass yet.", from: original)
            .errors.contains(FaithfulnessCheck.negationDropped))
    }

    func testAnAddedNegationIsNotAnError() {
        // The rule is one way on purpose: a rewrite that adds "never" is a
        // different failure, but it is not a dropped fact.
        let report = check("Never send Priya the report by 5 pm on Thursday and don't forget the appendix.")
        XCTAssertFalse(report.errors.contains(FaithfulnessCheck.negationDropped))
    }

    func testEveryNegationWordIsCounted() {
        let original = "No one was there without the key, except Sam, who never was."
        let stripped = "Someone was there with the key, and Sam, who was."
        XCTAssertTrue(check(stripped, from: original, style: .formal)
            .errors.contains(FaithfulnessCheck.negationDropped))
    }

    func testThePlainWordNoCounts() {
        let report = check("There is a problem.", from: "There is no problem.", style: .formal)
        XCTAssertTrue(report.errors.contains(FaithfulnessCheck.negationDropped))
    }

    // MARK: - Added artefacts

    func testAnAddedURLIsAnError() {
        let report = check(
            "Send Priya the report by 5 pm Thursday and don't forget the appendix at https://example.com/a."
        )
        XCTAssertTrue(report.errors.contains(FaithfulnessCheck.somethingAdded))
    }

    func testAnAddedEmailIsAnError() {
        let report = check(
            "Send Priya the report by 5 pm Thursday and don't forget the appendix, mail sam@example.com."
        )
        XCTAssertTrue(report.errors.contains(FaithfulnessCheck.somethingAdded))
    }

    func testAnAddedFilePathIsAnError() {
        let report = check(
            "Send Priya the report from src/report.md by 5 pm Thursday and don't forget the appendix."
        )
        XCTAssertTrue(report.errors.contains(FaithfulnessCheck.somethingAdded))
    }

    func testAnAddedHomePathIsAnError() {
        let report = check(
            "Send Priya the report from ~/Documents/report.md by 5 pm and don't forget the appendix."
        )
        XCTAssertTrue(report.errors.contains(FaithfulnessCheck.somethingAdded))
    }

    func testAURLKeptFromTheOriginalIsNotAnError() {
        let original = "Send the report to Priya at https://example.com/a by 5 pm, don't forget it."
        let report = check(
            "Send the report to Priya at https://example.com/a by 5 pm; don't forget it.",
            from: original
        )
        XCTAssertFalse(report.errors.contains(FaithfulnessCheck.somethingAdded))
    }

    func testANewWordIsNotAnArtefact() {
        let report = check(
            "Send Priya the report by 5 pm on Thursday, and please don't forget the appendix."
        )
        XCTAssertFalse(report.errors.contains(FaithfulnessCheck.somethingAdded))
    }

    func testASlashThatIsNotAPathIsNotAnArtefact() {
        let report = check("Do this and/or that by 5 pm for Priya, and don't forget Thursday.")
        XCTAssertFalse(report.errors.contains(FaithfulnessCheck.somethingAdded))
    }
}

extension FaithfulnessCheckTests {
    // MARK: - The structure of a prompt

    private var brief: String {
        "Add a retry to the uploader in Sources/Uploader.swift, and 3 tests."
    }

    private var structured: String {
        """
        ## Goal
        Add a retry to the uploader and 3 tests.

        ## Context
        The uploader lives in Sources/Uploader.swift.

        ## Requirements
        1. Retry the upload in Sources/Uploader.swift.
        2. Add 3 tests.

        ## Constraints
        Do not change the public interface.

        ## Done when
        [missing: how to verify]
        """
    }

    func testAHeadingAndAListMarkerAreNotAddedArtefacts() {
        let report = FaithfulnessCheck.check(original: brief, rewrite: structured, style: .prompt)
        XCTAssertFalse(report.errors.contains(FaithfulnessCheck.somethingAdded), "\(report.errors)")
        XCTAssertFalse(report.errors.contains(FaithfulnessCheck.numberChanged), "\(report.errors)")
    }

    func testTheMissingMarkerIsNotAnAddedArtefact() {
        let rewrite = """
        ## Goal
        Add a retry to the uploader in Sources/Uploader.swift, and 3 tests.

        ## Open questions
        [missing: what]
        """
        let report = FaithfulnessCheck.check(original: brief, rewrite: rewrite, style: .prompt)
        XCTAssertFalse(report.errors.contains(FaithfulnessCheck.somethingAdded), "\(report.errors)")
    }

    func testThePromptStyleStillCatchesAURLTheSpeakerNeverSaid() {
        let rewrite = structured + "\n\nThe guide is at https://example.com/prompting."
        let report = FaithfulnessCheck.check(original: brief, rewrite: rewrite, style: .prompt)
        XCTAssertTrue(report.errors.contains(FaithfulnessCheck.somethingAdded))
        XCTAssertTrue(report.blocksApply)
    }

    func testThePromptStyleStillCatchesADroppedNumber() {
        let rewrite = structured.replacingOccurrences(of: "3", with: "")
        let report = FaithfulnessCheck.check(original: brief, rewrite: rewrite, style: .prompt)
        XCTAssertTrue(report.errors.contains(FaithfulnessCheck.numberChanged))
    }

    func testADroppedNegationIsAnErrorInAPromptToo() {
        let original = "Add a retry, but do not change the public interface."
        let rewrite = """
        ## Goal
        Add a retry and change the public interface.
        """
        let report = FaithfulnessCheck.check(original: original, rewrite: rewrite, style: .prompt)
        XCTAssertTrue(report.errors.contains(FaithfulnessCheck.negationDropped))
    }
}

extension FaithfulnessCheckTests {
    // MARK: - Names

    func testADroppedNameIsAWarning() {
        let report = check("Send the report by 5 pm on Thursday and don't forget the appendix.")
        XCTAssertTrue(report.warnings.contains(FaithfulnessCheck.nameChanged))
        XCTAssertFalse(report.errors.contains(FaithfulnessCheck.nameChanged))
    }

    func testANameInAnotherCaseIsStillThere() {
        let report = check("Send PRIYA the report by 5 pm on Thursday and don't forget the appendix.")
        XCTAssertFalse(report.warnings.contains(FaithfulnessCheck.nameChanged))
    }

    func testTheNameCheckIsSkippedForThePromptStyle() {
        // The prompt restructures the words into sections, so a name that moved
        // into a heading is not a name that changed.
        let original = "Add a retry to the uploader in Xcode by Tuesday."
        let rewrite = """
        Goal: Add a retry to the uploader. Context: Xcode. Constraints: none. Done when: it ships.
        """
        let report = FaithfulnessCheck.check(original: original, rewrite: rewrite, style: .prompt)
        XCTAssertFalse(report.warnings.contains(FaithfulnessCheck.nameChanged))
        // The same rewrite under a style that checks names does warn.
        let plain = FaithfulnessCheck.check(original: original, rewrite: rewrite, style: .plain)
        XCTAssertTrue(plain.warnings.contains(FaithfulnessCheck.nameChanged))
    }

    func testASentenceInitialCapitalIsNotAName() {
        let original = "Send it now. Then call Priya."
        // Both "Send" and "Then" are sentence-initial and may be reworded.
        let report = check("Pass it now. And call Priya.", from: original)
        XCTAssertFalse(report.warnings.contains(FaithfulnessCheck.nameChanged))
    }

    func testAOneLetterCapitalIsNotAName() {
        let report = check(
            "i will send the report to Priya by 5 pm on Thursday and not forget the appendix.",
            from: "I will send the report to Priya by 5 pm on Thursday and not forget the appendix.",
            style: .casual
        )
        XCTAssertFalse(report.warnings.contains(FaithfulnessCheck.nameChanged))
    }

    // MARK: - Length

    func testATooShortRewriteIsAWarning() {
        let report = check("Send it to Priya.", style: .concise)
        XCTAssertTrue(report.warnings.contains(FaithfulnessCheck.lengthChanged))
    }

    func testATooLongRewriteIsAWarning() {
        let long = (0 ..< 6).map { _ in original }.joined(separator: " ")
        let report = check(long, style: .formal)
        XCTAssertTrue(report.warnings.contains(FaithfulnessCheck.lengthChanged))
    }

    func testTheBandIsReadFromTheStyle() {
        // 0.45 of the original: inside the prompt and formal bands, outside the
        // concise band.
        let shortened = "Send Priya the report by 5 pm Thursday; the appendix is not forgotten."
        let concise = check(shortened, style: .concise)
        XCTAssertTrue(concise.warnings.contains(FaithfulnessCheck.lengthChanged))
        let formal = check(shortened, style: .formal)
        XCTAssertFalse(formal.warnings.contains(FaithfulnessCheck.lengthChanged))
    }

    func testTheBottomOfTheConciseBandIsAccepted() {
        let report = check(
            "Priya gets the report at 5 on Thursday, no appendix left out.",
            style: .concise
        )
        XCTAssertFalse(report.warnings.contains(FaithfulnessCheck.lengthChanged))
    }

    func testAnEmptyOriginalSkipsTheLengthCheck() {
        let report = FaithfulnessCheck.check(original: "", rewrite: "Anything.", style: .concise)
        XCTAssertFalse(report.warnings.contains(FaithfulnessCheck.lengthChanged))
    }

    // MARK: - Report

    func testTheFirstErrorAndWarningAreExposed() {
        let report = FaithfulnessCheck.check(
            original: "Send 3 files to Priya, don't send them twice.",
            rewrite: "Send four files, send them twice. See https://example.com/x.",
            style: .plain
        )
        XCTAssertEqual(report.firstError, FaithfulnessCheck.numberChanged)
        XCTAssertEqual(report.firstWarning, FaithfulnessCheck.nameChanged)
        XCTAssertTrue(report.errors.count >= 2)
    }

    func testTheReportIsAnEquatableValue() {
        let first = FaithfulnessReport(errors: [FaithfulnessCheck.numberChanged], warnings: [])
        let second = FaithfulnessReport(errors: [FaithfulnessCheck.numberChanged], warnings: [])
        XCTAssertEqual(first, second)
        XCTAssertTrue(first.blocksApply)
        XCTAssertEqual(FaithfulnessReport().errors, [])
        XCTAssertTrue(FaithfulnessReport().isFaithful)
    }
}
