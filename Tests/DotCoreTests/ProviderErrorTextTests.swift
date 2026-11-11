import XCTest

@testable import DotCore

/// The text of a failed answer.
///
/// A service, or a proxy in front of one, answers a failed request with
/// anything it likes. The message goes on the card and into the log, so it is
/// flattened and capped before either of them sees it.
final class ProviderErrorTextTests: XCTestCase {
    func testAShortMessageIsKeptAsItIs() {
        XCTAssertEqual(
            ProviderErrorText.sanitized("Invalid API key"),
            "Invalid API key"
        )
    }

    func testTheMessageIsFlattenedToOneLine() {
        XCTAssertEqual(
            ProviderErrorText.sanitized("rate limit\nexceeded\r\n\tfor this key"),
            "rate limit exceeded for this key"
        )
    }

    func testAnEmptyMessageIsNothingAtAll() {
        XCTAssertNil(ProviderErrorText.sanitized(nil))
        XCTAssertNil(ProviderErrorText.sanitized(""))
        XCTAssertNil(ProviderErrorText.sanitized("   \n\t "))
    }

    func testAnHTMLPageIsCappedAndMarkedAsCut() {
        let page = "<html><body>" + String(repeating: "access denied. ", count: 500) + "</body></html>"
        let message = ProviderErrorText.sanitized(page) ?? ""

        XCTAssertEqual(message.count, ProviderErrorText.maximumCharacters)
        XCTAssertTrue(message.hasSuffix("…"), "a cut message has to say it was cut")
        XCTAssertFalse(message.contains("\n"))
        XCTAssertLessThan(message.count, page.count)
    }

    func testControlCharactersNeverReachTheCard() {
        let message = ProviderErrorText.sanitized("bad\u{0000}answer\u{0007}") ?? ""
        XCTAssertEqual(message, "bad answer")
    }

    func testTheProviderPathCapsWhatTheServiceSent() {
        // Groq repeats the body when it holds no JSON: the head of an HTML page
        // was put into the log and onto the card verbatim.
        let page = Data(String(repeating: "<html>denied</html>\n", count: 2_000).utf8)
        let message = GroqProvider.errorMessage(in: page)
        XCTAssertLessThanOrEqual(message.count, ProviderErrorText.maximumCharacters)
        XCTAssertFalse(message.contains("\n"))
    }

    func testTheAzurePathCapsWhatTheServiceSent() {
        let page = Data(String(repeating: "<html>401</html>\n", count: 2_000).utf8)
        let message = AzureSpeechProvider.errorMessage(in: page) ?? ""
        XCTAssertLessThanOrEqual(message.count, ProviderErrorText.maximumCharacters)
    }

    func testTheDescriptionOfARejectedRequestIsCapped() {
        let long = String(repeating: "x", count: 5_000)
        let error = ProviderError.rejected(status: 400, message: long)
        let description = error.errorDescription ?? ""
        XCTAssertLessThan(description.count, 400)
    }

    func testAnEmptyRejectedMessageSaysOnlyTheStatus() {
        XCTAssertEqual(
            ProviderError.rejected(status: 503, message: "").errorDescription,
            "The service answered HTTP 503."
        )
    }
}
