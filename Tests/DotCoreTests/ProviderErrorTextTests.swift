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

    // MARK: - Credentials in a response body

    func testAVendorKeyInTheBodyIsRedacted() {
        let secret = "sk-live-0123456789abcdef"
        let message = ProviderErrorText.sanitized(
            #"{"error":"invalid key \#(secret)"}"#
        ) ?? ""
        XCTAssertFalse(message.contains(secret))
        XCTAssertTrue(message.contains(ProviderErrorText.redaction))
    }

    func testABearerTokenIsRedacted() {
        let message = ProviderErrorText.sanitized(
            "Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.payload.signature"
        ) ?? ""
        XCTAssertFalse(message.contains("eyJhbGciOiJIUzI1NiJ9"))
        XCTAssertTrue(message.contains(ProviderErrorText.redaction))
    }

    func testAQueryOrJSONCredentialIsRedacted() {
        for body in [
            "https://example.com/callback?api_key=abcd1234efgh",
            #"{"access_token":"abcd1234efgh","ok":false}"#,
            "x-api-key: abcd1234efgh",
            "secret=abcd1234efgh",
            "password: hunter2hunter2",
        ] {
            let message = ProviderErrorText.sanitized(body) ?? ""
            XCTAssertFalse(
                message.contains("abcd1234efgh") || message.contains("hunter2hunter2"),
                "a credential survived: \(body) -> \(message)"
            )
        }
    }

    func testOrdinaryWordsAboutAKeyAreNotRedacted() {
        XCTAssertEqual(ProviderErrorText.sanitized("Invalid API key"), "Invalid API key")
        XCTAssertEqual(
            ProviderErrorText.sanitized("The token is missing from the request."),
            "The token is missing from the request."
        )
        XCTAssertEqual(
            ProviderErrorText.sanitized("No password was sent."),
            "No password was sent."
        )
    }

    func testARejectedRequestThatRepeatsTheTokenDoesNotShowIt() {
        let secret = "sk-live-0123456789abcdef"
        let description = ProviderError.rejected(
            status: 401,
            message: #"{"error":"bad key \#(secret)"}"#
        ).errorDescription ?? ""
        XCTAssertFalse(description.contains(secret))
    }
}
