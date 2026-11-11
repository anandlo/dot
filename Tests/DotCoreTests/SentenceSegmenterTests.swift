import XCTest

@testable import DotCore

/// The segmenter decides where speech can start, so a wrong cut is audible:
/// a pause after a title, "three" and "fourteen" instead of "3.14", a URL read
/// as a list of words. These tests hold the rules that make a cut sound like a
/// sentence and never like a parser.
final class SentenceSegmenterTests: XCTestCase {
    /// Every sentence the segmenter produces for a complete answer.
    ///
    /// The tail is flushed because a lone terminator at the end of a buffer is
    /// deliberately held: the next chunk may be "e.g." or "example.com". A real
    /// turn flushes when the model stops, which is what this models.
    private func sentences(_ text: String) -> [String] {
        var segmenter = SentenceSegmenter()
        return segmenter.append(text) + segmenter.flush()
    }
    func testSplitsPlainSentences() {
        XCTAssertEqual(
            sentences("The build passed. Then the tests ran! Did they finish?"),
            ["The build passed.", "Then the tests ran!", "Did they finish?"]
        )
    }

    func testHoldsATrailingTerminatorUntilMoreTextArrives() {
        var segmenter = SentenceSegmenter()
        XCTAssertEqual(segmenter.append("The build passed."), [])
        XCTAssertEqual(segmenter.append(" Then it shipped."), ["The build passed."])
        XCTAssertEqual(segmenter.flush(), ["Then it shipped."])
    }

    func testAbbreviationsDoNotEndASentence() {
        let text = "Dr. Smith met Prof. Jones at 9 a.m. in St. Louis. They talked, e.g. about the U.S. plan."
        XCTAssertEqual(
            sentences(text),
            [
                "Dr. Smith met Prof. Jones at 9 a.m. in St. Louis.",
                "They talked, e.g. about the U.S. plan.",
            ]
        )
    }

    func testDecimalIsNotSplit() {
        XCTAssertEqual(
            sentences("Pi is 3.14 and e is 2.71 today. That is all."),
            ["Pi is 3.14 and e is 2.71 today.", "That is all."]
        )
    }

    func testVersionNumberIsNotSplit() {
        XCTAssertEqual(
            sentences("It ships in v1.2.3 of the package. Then we tag it."),
            ["It ships in v1.2.3 of the package.", "Then we tag it."]
        )
    }

    func testURLIsNotSplit() {
        XCTAssertEqual(
            sentences("Read https://example.com/a.b first. Then stop."),
            ["Read https://example.com/a.b first.", "Then stop."]
        )
    }

    func testIdentifierIsNotSplit() {
        XCTAssertEqual(
            sentences("Call foo.bar(x) then wait. It returns."),
            ["Call foo.bar(x) then wait.", "It returns."]
        )
    }

    func testInitialsDoNotEndASentence() {
        XCTAssertEqual(
            sentences("J. K. Rowling wrote it. Then she stopped."),
            ["J. K. Rowling wrote it.", "Then she stopped."]
        )
    }

    func testEllipsisAndExclamationRunEndTheSentence() {
        XCTAssertEqual(
            sentences("Wait... What?! Fine."),
            ["Wait...", "What?!", "Fine."]
        )
    }

    func testCJKPunctuationEndsASentenceWithoutASpace() {
        var segmenter = SentenceSegmenter()
        XCTAssertEqual(
            segmenter.append("你好。今天很好！"),
            ["你好。", "今天很好！"]
        )
    }

    func testQuotedSentenceKeepsItsClosingMark() {
        XCTAssertEqual(
            sentences("She said \"go.\" He went."),
            ["She said \"go.\"", "He went."]
        )
    }

    func testBlankLineEndsASentenceWithoutPunctuation() {
        var segmenter = SentenceSegmenter()
        XCTAssertEqual(
            segmenter.append("First line\n\nSecond line"),
            ["First line"]
        )
    }

    func testPunctuationAloneIsNotSpeakable() {
        var segmenter = SentenceSegmenter()
        XCTAssertEqual(segmenter.append("… "), [])
        XCTAssertEqual(segmenter.flush(), [])
    }

    func testFlushReturnsTheTail() {
        var segmenter = SentenceSegmenter()
        XCTAssertEqual(segmenter.append("No terminator here"), [])
        XCTAssertEqual(segmenter.flush(), ["No terminator here"])
        XCTAssertEqual(segmenter.flush(), [])
    }
}

// MARK: - Chunking and caps

extension SentenceSegmenterTests {
    func testCharacterByCharacterMatchesTheWholeAnswer() {
        let text = "Dr. Smith paid 3.14 for it. Read example.com/a.b first! Was that right? Yes... it was."
        var whole = SentenceSegmenter()
        var streamed = SentenceSegmenter()
        let expected = whole.append(text) + whole.flush()
        var actual: [String] = []
        for character in text {
            actual += streamed.append(String(character))
        }
        actual += streamed.flush()
        XCTAssertEqual(actual, expected)
        XCTAssertEqual(expected.count, 5)
    }

    func testARunOnIsCutAtAClause() {
        var segmenter = SentenceSegmenter()
        let opening = String(repeating: "a", count: 50)
        let closing = String(repeating: "b", count: 70)
        let sentences = segmenter.append("\(opening), \(closing) and then more")
        XCTAssertEqual(sentences, ["\(opening),"])
    }

    func testARunOnWithNoSpaceIsNotCutMidNumber() {
        var segmenter = SentenceSegmenter()
        let opening = String(repeating: "a", count: 100)
        let closing = String(repeating: "b", count: 200)
        let sentences = segmenter.append("\(opening)3 000\(closing)")
        XCTAssertEqual(sentences, [], "a cut between two digits would say the number twice")
        XCTAssertEqual(segmenter.flush().count, 1)
    }

    func testARunOnWithoutNumbersIsCutAtASpace() {
        var segmenter = SentenceSegmenter()
        let text = String(repeating: "word ", count: 80)
        let sentences = segmenter.append(text)
        XCTAssertEqual(sentences.count, 1)
        let first = sentences[0]
        XCTAssertGreaterThanOrEqual(first.count, SentenceSegmenter.minimumClauseCharacters)
        XCTAssertLessThanOrEqual(first.count, SentenceSegmenter.maximumSegmentCharacters)
        XCTAssertFalse(first.hasSuffix(" "))
    }

    func testResetForgetsTheTail() {
        var segmenter = SentenceSegmenter()
        _ = segmenter.append("Half a sentence")
        segmenter.reset()
        XCTAssertEqual(segmenter.flush(), [])
    }

    func testEmptyInputDoesNothing() {
        var segmenter = SentenceSegmenter()
        XCTAssertEqual(segmenter.append(""), [])
        XCTAssertEqual(segmenter.flush(), [])
    }
}
