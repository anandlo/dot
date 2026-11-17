import XCTest

@testable import DotCore

/// When the card offers the chips.
///
/// It is one rule, shared by the card, Settings and the paste path that decides
/// whether the insertion is anchored: a take that is not offered must not touch
/// the Accessibility API at all.
final class RewriteOfferTests: XCTestCase {
    private let text = "Send the report to Priya by 5 pm."

    /// An assistant the person set up, on the row the test asks about.
    private func setUpAssistant(
        providerID: String = AssistantSettings.defaultProviderID,
        baseURL: String? = nil
    ) -> AssistantConfiguration {
        var configuration = AssistantConfiguration.default
        configuration.isSetUp = true
        configuration.chat.providerID = providerID
        configuration.chat.baseURL = baseURL
        return configuration
    }

    private func offers(
        rewrite: RewriteConfiguration = .default,
        assistant: AssistantConfiguration? = nil,
        hasKey: Bool = true,
        text: String? = nil,
        delivery: HUDDelivery = .pasted
    ) -> Bool {
        RewriteOffer.shouldOffer(
            rewrite: rewrite,
            assistant: assistant ?? setUpAssistant(),
            hasKey: hasKey,
            text: text ?? self.text,
            delivery: delivery
        )
    }

    func testAServiceWithAKeyOffersTheChips() {
        XCTAssertTrue(offers())
    }

    func testAServiceWithoutAKeyOffersNothing() {
        XCTAssertFalse(offers(hasKey: false))
    }

    func testAServiceOnThisMacNeedsNoKey() {
        XCTAssertTrue(offers(assistant: setUpAssistant(providerID: "ollama"), hasKey: false))
        XCTAssertTrue(offers(assistant: setUpAssistant(providerID: "lmstudio"), hasKey: false))
    }

    func testAnUnknownServiceIsTreatedAsACustomEndpoint() {
        // A custom row needs no key, which is what a hand-filled endpoint is.
        // It still needs an address: a row with no address reaches no service.
        XCTAssertTrue(offers(
            assistant: setUpAssistant(providerID: "my-endpoint", baseURL: "https://proxy.example.com/v1"),
            hasKey: false
        ))
        XCTAssertFalse(
            offers(assistant: setUpAssistant(providerID: "my-endpoint"), hasKey: false),
            "a custom endpoint with no address was offered"
        )
    }

    /// The report's state: a custom endpoint, set up on paper, no address.
    ///
    /// The chips used to be offered here and every rewrite then failed while
    /// the provider was built. The offer and the status row now ask one rule.
    func testACustomEndpointWithNoAddressOffersNoChips() {
        let assistant = setUpAssistant(providerID: "custom")
        XCTAssertFalse(offers(assistant: assistant, hasKey: false))
        XCTAssertEqual(
            AssistantAvailability.readiness(config: assistant, hasKey: false),
            .missingAddress
        )
    }

    /// The page's explanatory line and the card's offer are one answer.
    ///
    /// Every case of the readiness rule is checked against the offer: a record
    /// the page calls ready must offer the chips, and a record it explains must
    /// not. A second opinion in either place would fail this table.
    func testTheOfferAgreesWithTheSettingsExplanation() {
        let states: [(name: String, assistant: AssistantConfiguration, hasKey: Bool)] = [
            ("fresh install", AssistantConfiguration.default, true),
            ("custom without an address", setUpAssistant(providerID: "custom"), false),
            ("custom at a loopback address",
             setUpAssistant(providerID: "custom", baseURL: "http://127.0.0.1:8080/v1"), false),
            ("custom at a remote http address",
             setUpAssistant(providerID: "custom", baseURL: "http://api.example.com/v1"), false),
            ("custom at an https address",
             setUpAssistant(providerID: "custom", baseURL: "https://proxy.example.com/v1"), false),
            ("ollama at its shipped address", setUpAssistant(providerID: "ollama"), false),
            ("a keyed service with its key", setUpAssistant(providerID: "openai"), true),
            ("a keyed service without its key", setUpAssistant(providerID: "openai"), false),
            ("a record that names no service",
             setUpAssistant(providerID: "  "), true),
        ]
        for state in states {
            let readiness = AssistantAvailability.readiness(
                config: state.assistant,
                hasKey: state.hasKey
            )
            let offered = offers(assistant: state.assistant, hasKey: state.hasKey)
            XCTAssertEqual(
                offered,
                readiness.isReady,
                "\(state.name): the card and the page disagree"
            )
            XCTAssertEqual(
                readiness.message == nil,
                readiness.isReady,
                "\(state.name): a ready record may not explain a problem"
            )
        }
    }

    func testASpeechKeyAloneOffersNoChips() {
        // The chat key is the speech key's own Keychain item: a person who set
        // the transcriber up has one and never chose an assistant, and the
        // chips must not appear in front of them.
        let never = AssistantConfiguration.default
        XCTAssertFalse(never.isSetUp, "a configuration this build wrote is not set up")
        XCTAssertFalse(offers(assistant: never, hasKey: true))
    }

    func testALocalServiceIsNotOfferedBeforeTheAssistantIsSetUp() {
        XCTAssertFalse(offers(assistant: AssistantConfiguration.default, hasKey: false))
        var local = AssistantConfiguration.default
        local.chat.providerID = "ollama"
        XCTAssertFalse(offers(assistant: local, hasKey: false))
    }

    func testTheSwitchTurnsTheChipsOff() {
        var rewrite = RewriteConfiguration.default
        rewrite.enabled = false
        XCTAssertFalse(offers(rewrite: rewrite))
    }

    func testNoChosenStyleMeansNoChips() {
        let rewrite = RewriteConfiguration(enabled: true, styles: [], custom: [])
        XCTAssertFalse(offers(rewrite: rewrite))
    }

    func testOnlyTheStylesThatAreOnAreOffered() {
        let rewrite = RewriteConfiguration(styles: [.concise, .formal])
        XCTAssertEqual(rewrite.choices.map(\.title), ["Concise", "Professional"])
        XCTAssertTrue(offers(rewrite: rewrite))
    }

    func testTheLengthBounds() {
        XCTAssertFalse(offers(text: ""))
        XCTAssertFalse(offers(text: "   "))
        XCTAssertTrue(offers(text: "a"))
        XCTAssertTrue(offers(text: String(repeating: "a", count: 3_000)))
        XCTAssertFalse(offers(text: String(repeating: "a", count: 3_001)))
    }

    func testAFailedTakeIsNeverOffered() {
        XCTAssertFalse(offers(delivery: .failed))
        XCTAssertTrue(offers(delivery: .copied), "a copy is rewritten onto the clipboard")
        XCTAssertTrue(offers(delivery: .pasted))
    }

}
