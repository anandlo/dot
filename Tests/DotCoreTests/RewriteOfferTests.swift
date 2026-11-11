import XCTest

@testable import DotCore

/// When the card offers the chips.
///
/// It is one rule, shared by the card, Settings and the paste path that decides
/// whether the insertion is anchored: a take that is not offered must not touch
/// the Accessibility API at all.
final class RewriteOfferTests: XCTestCase {
    private let text = "Send the report to Priya by 5 pm."

    private func offers(
        rewrite: RewriteConfiguration = .default,
        providerID: String = AssistantSettings.defaultProviderID,
        hasKey: Bool = true,
        text: String? = nil,
        delivery: HUDDelivery = .pasted
    ) -> Bool {
        RewriteOffer.shouldOffer(
            rewrite: rewrite,
            providerID: providerID,
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
        XCTAssertTrue(offers(providerID: "ollama", hasKey: false))
        XCTAssertTrue(offers(providerID: "lmstudio", hasKey: false))
    }

    func testAnUnknownServiceIsTreatedAsACustomEndpoint() {
        // A custom row needs no key, which is what a hand-filled endpoint is.
        XCTAssertTrue(offers(providerID: "my-endpoint", hasKey: false))
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

    func testTheServiceIsUsableWhenTheRowNeedsNoKey() {
        XCTAssertTrue(RewriteOffer.serviceIsUsable(providerID: "ollama", hasKey: false))
        XCTAssertTrue(RewriteOffer.serviceIsUsable(providerID: "anthropic", hasKey: true))
        XCTAssertFalse(RewriteOffer.serviceIsUsable(providerID: "anthropic", hasKey: false))
    }
}
