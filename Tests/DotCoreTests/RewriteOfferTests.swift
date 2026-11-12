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
        providerID: String = AssistantSettings.defaultProviderID
    ) -> AssistantConfiguration {
        var configuration = AssistantConfiguration.default
        configuration.isSetUp = true
        configuration.chat.providerID = providerID
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
        XCTAssertTrue(offers(assistant: setUpAssistant(providerID: "my-endpoint"), hasKey: false))
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
        XCTAssertEqual(rewrite.choices.map(\.title), ["Concise", "Formal"])
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
