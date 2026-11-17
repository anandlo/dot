import AppKit
import DotCore
import SwiftUI
import XCTest

@testable import Dot

/// The Assistant page when the record it opens is not usable.
///
/// The page is hosted offscreen: no window, no display and no network, and the
/// keyed providers are the ones the test names, so nothing reads the Keychain.
/// The question here is not how the card looks but whether a person can see the
/// service their record names and reach the fields that finish it.
@MainActor
final class AssistantSetupDiscoverabilityTests: XCTestCase {
    /// The record the report was made with: `isSetUp` false, a custom endpoint,
    /// no address and no key, written before the choice flag existed.
    private var reported: DotConfig {
        var config = DotConfig.default
        config.assistant.isSetUp = false
        config.assistant.chat = AssistantSettings(providerID: "custom")
        return config
    }

    /// A record a fresh install writes, with a speech key the Provider page left
    /// behind and no assistant chosen.
    private var neverChosen: DotConfig {
        var config = DotConfig.default
        config.assistant.isSetUp = false
        config.assistant.chat = AssistantSettings(providerID: AssistantSettings.defaultProviderID)
        return config
    }

    /// A service that is set up and can be reached.
    private var ready: DotConfig {
        var config = DotConfig.default
        config.assistant.isSetUp = true
        config.assistant.chat = AssistantSettings(
            providerID: AssistantSettings.defaultProviderID,
            model: "gpt-4o-mini"
        )
        return config
    }

    private func host(_ config: DotConfig, keyed: Set<String> = []) -> NSHostingView<AnyView> {
        let page = AssistantPage(
            config: .constant(config),
            onChange: {},
            onSetKey: { _, _ in nil },
            onDeleteKey: { _ in nil }
        )
        .environment(\.settingsHeadless, true)
        .environment(\.assistantKeyedProviders, keyed)
        .environment(\.assistantConnectionPreview, .notSetUp)
        let host = NSHostingView(rootView: AnyView(page))
        host.frame = NSRect(x: 0, y: 0, width: 640, height: 900)
        host.layoutSubtreeIfNeeded()
        return host
    }

    private func select(_ label: String, in view: NSView?) -> DotSelectAccessibilityView? {
        guard let view else { return nil }
        if let element = view as? DotSelectAccessibilityView, element.accessibilityLabel() == label {
            return element
        }
        for sub in view.subviews {
            if let found = select(label, in: sub) { return found }
        }
        return nil
    }

    private func textField(placeholder: String, in view: NSView?) -> NSTextField? {
        guard let view else { return nil }
        if let field = view as? NSTextField, field.placeholderString == placeholder {
            return field
        }
        for sub in view.subviews {
            if let found = textField(placeholder: placeholder, in: sub) { return found }
        }
        return nil
    }

    // MARK: - The unusable record

    /// The service is shown, not hidden behind "None".
    ///
    /// A custom endpoint picked and then left unfinished used to open as an
    /// untouched install, so the address field could not even be reached.
    func testACustomEndpointWithNoAddressIsShownAsChosen() throws {
        let host = host(reported)
        let service = try XCTUnwrap(select("Service", in: host), "the page has no Service pop-up")
        XCTAssertEqual(service.accessibilityValue() as? String, "Custom endpoint")
    }

    func testTheAddressFieldIsReachableWhileTheRecordIsNotUsable() throws {
        let host = host(reported)
        let address = try XCTUnwrap(
            textField(placeholder: "https://…", in: host),
            "the custom endpoint has no address field"
        )
        XCTAssertEqual(address.stringValue, "", "the field starts empty, not with a made-up address")
    }

    /// Setup is still possible: the key field is there for a proxy that needs
    /// one, and no model or delivery settings claim the assistant is ready.
    func testTheKeyFieldIsShownAndTheReadySectionsAreNot() throws {
        let host = host(reported)
        XCTAssertNotNil(
            textField(placeholder: "API key", in: host),
            "the person cannot finish setting the service up"
        )
        XCTAssertNil(select("Model", in: host), "a model was offered for a service that cannot be reached")
        XCTAssertNil(
            select("Deliver answers", in: host),
            "an answers section was offered for a service that cannot be reached"
        )
    }

    /// A speech key is not a choice of assistant: the page offers the key rather
    /// than turning the assistant on, and the ready sections stay away.
    func testASpeechKeyAloneLeavesThePageInSetup() throws {
        let host = host(neverChosen, keyed: [AssistantSettings.defaultProviderID])
        let service = try XCTUnwrap(select("Service", in: host))
        XCTAssertEqual(service.accessibilityValue() as? String, "None")
        XCTAssertNil(select("Model", in: host), "the speech key turned the assistant on")
        XCTAssertEqual(
            AssistantAvailability.readiness(
                config: neverChosen.assistant,
                hasKey: true
            ),
            .notSetUp
        )
    }

    // MARK: - A record that is ready

    /// The master switch decides whether the setup is presented at all.
    ///
    /// A configured record with rewriting off is not an untouched install: the
    /// switch card is drawn, the service and model cards are not, and the
    /// record keeps every value the switch is not about.
    func testTheMasterSwitchDecidesWhetherTheReadyCardsArePresented() throws {
        var config = ready
        config.assistant.rewrite.enabled = false
        XCTAssertTrue(config.assistant.isSetUp)

        let offPage = host(config, keyed: [AssistantSettings.defaultProviderID])
        XCTAssertNil(
            select("Service", in: offPage),
            "a page with rewriting off still offered its service"
        )
        XCTAssertNil(
            select("Model", in: offPage),
            "a page with rewriting off still offered its model"
        )
        XCTAssertEqual(
            AssistantPage.cards(config: config.assistant, hasKey: true).map(\.title),
            ["AI rewrite"],
            "the switch did not hide the cards it governs"
        )
        XCTAssertEqual(
            config.assistant.chat,
            ready.assistant.chat,
            "the switch changed the service or its model"
        )

        config.assistant.rewrite.enabled = true
        let restored = host(config, keyed: [AssistantSettings.defaultProviderID])
        XCTAssertNotNil(select("Service", in: restored))
        XCTAssertNotNil(select("Model", in: restored))
        XCTAssertEqual(
            AssistantPage.cards(config: config.assistant, hasKey: true).map(\.title),
            ["AI rewrite", "Service", "Model", "Styles"]
        )
    }

    /// The same predicate that hides the setup rows shows the ready ones.
    ///
    /// Answers are not part of this product: a configured service offers its
    /// model and the style controls, and no answer destination at all.
    func testAUsableServiceShowsTheModelAndStylesCards() throws {
        let host = host(ready, keyed: [AssistantSettings.defaultProviderID])
        let service = try XCTUnwrap(select("Service", in: host))
        XCTAssertEqual(
            service.accessibilityValue() as? String,
            "OpenAI",
            "a service that is set up is named even when it is the build's default"
        )
        XCTAssertNotNil(select("Model", in: host), "a usable service offers its model")
        XCTAssertNil(
            select("Deliver answers", in: host),
            "answer delivery is not a setting of AI rewrite"
        )
        XCTAssertNil(
            textField(placeholder: "https://…", in: host),
            "a row that ships its address does not ask for one"
        )
    }

    /// A proxy typed over a row that ships an address stays editable.
    func testATypedProxyAddressStaysEditable() throws {
        var config = ready
        config.assistant.chat.baseURL = "https://proxy.example.com/v1"
        let host = host(config, keyed: [AssistantSettings.defaultProviderID])
        let field = try XCTUnwrap(
            textField(placeholder: "https://api.openai.com/v1", in: host),
            "the stored proxy address has no field"
        )
        XCTAssertEqual(field.stringValue, "https://proxy.example.com/v1")
    }

    // MARK: - The explicit switch

    /// A keyless service that is named but not set up gets one button that says
    /// so, and a keyed service is set up by its key instead.
    func testOnlyAKeylessChosenServiceOffersTheTurnOnSwitch() {
        var custom = DotConfig.default
        custom.assistant.chat.providerID = "custom"
        XCTAssertTrue(AssistantPage.namesService(custom.assistant))
        XCTAssertTrue(
            AssistantPage.needsTurnOn(config: custom.assistant, isServiceChosen: true),
            "the reported record has no other way to be turned on"
        )
        XCTAssertFalse(
            AssistantPage.needsTurnOn(config: custom.assistant, isServiceChosen: false),
            "a fresh install is not asked to turn a service on"
        )

        var keyed = DotConfig.default
        keyed.assistant.chat.providerID = "openai"
        XCTAssertFalse(
            AssistantPage.needsTurnOn(config: keyed.assistant, isServiceChosen: true),
            "a keyed service is set up by its key, not by this button"
        )

        var local = DotConfig.default
        local.assistant.isSetUp = true
        local.assistant.chat.providerID = "ollama"
        XCTAssertFalse(
            AssistantPage.needsTurnOn(config: local.assistant, isServiceChosen: true),
            "a service that is already on is not offered the switch again"
        )
    }

    func testAFreshRecordNamesNoService() {
        XCTAssertFalse(AssistantPage.namesService(neverChosen.assistant))
        XCTAssertFalse(
            AssistantPage.namesService(AssistantConfiguration.default),
            "the id a build writes is not a choice"
        )
        var blank = AssistantConfiguration.default
        blank.chat.providerID = ""
        XCTAssertFalse(
            AssistantPage.namesService(blank),
            "a hand-edited blank reads as the build's default, not as a chosen service"
        )
        XCTAssertTrue(AssistantPage.namesService(reported.assistant))
    }

    /// The page's explanation is the rule's own sentence, and it never carries
    /// the address or a key.
    func testThePageExplainsTheMissingAddressWithoutRepeatingTheRecord() {
        var config = reported
        config.assistant.isSetUp = true
        config.assistant.chat.baseURL = "https://user:sk-live-0123456789abcdef@proxy.example.com/v1/"
        let readiness = AssistantAvailability.readiness(config: config.assistant, hasKey: false)
        XCTAssertTrue(readiness.isReady, "the address itself is a fine https address")

        config.assistant.chat.baseURL = nil
        let explained = AssistantAvailability.readiness(config: config.assistant, hasKey: false)
        XCTAssertEqual(explained.message, "Add the address this service is reached at.")
        XCTAssertFalse((explained.message ?? "").contains("https://"))
        XCTAssertFalse((explained.message ?? "").contains("sk-"))
    }

    // MARK: - Choosing a service, and turning it on

    /// A custom endpoint is not switched on by its pick.
    ///
    /// The old rule read "asks for no key" as "is ready", which is how a custom
    /// record came to claim it was set up while it had no address at all.
    func testPickingACustomEndpointWaitsForTheExplicitSwitch() {
        var config = AssistantConfiguration.default
        AssistantPage.choose("custom", in: &config)
        XCTAssertEqual(config.serviceChosen, true)
        XCTAssertFalse(config.isSetUp, "picking a custom endpoint switched it on")
        XCTAssertTrue(AssistantPage.presentsService(config))
        XCTAssertTrue(
            AssistantPage.needsTurnOn(
                config: config,
                isServiceChosen: AssistantPage.presentsService(config)
            )
        )
        XCTAssertFalse(AssistantPage.canTurnOn(config), "there is no address to reach yet")

        config.chat.baseURL = "https://proxy.example.com/v1"
        XCTAssertTrue(AssistantPage.canTurnOn(config), "a usable address enables the switch")
        AssistantPage.turnOn(&config)
        XCTAssertTrue(config.isSetUp)
        XCTAssertEqual(config.serviceChosen, true)
        XCTAssertTrue(
            AssistantAvailability.isUsable(config: config, hasKey: false),
            "the turn-on and the chips' rule agree"
        )
    }

    /// Only a shipped row that runs on this Mac is switched on by its pick.
    func testPickingAKnownLocalServiceIsTheWholeSetup() {
        for id in ["ollama", "lmstudio"] {
            var config = AssistantConfiguration.default
            AssistantPage.choose(id, in: &config)
            XCTAssertTrue(config.isSetUp, id)
            XCTAssertEqual(config.serviceChosen, true, id)
        }

        XCTAssertTrue(AssistantPage.turnsOnWhenPicked(AssistantProviderCatalogue.row(for: "ollama")))
        XCTAssertTrue(AssistantPage.turnsOnWhenPicked(AssistantProviderCatalogue.row(for: "lmstudio")))
        XCTAssertFalse(AssistantPage.turnsOnWhenPicked(AssistantProviderCatalogue.row(for: "custom")))
        XCTAssertFalse(AssistantPage.turnsOnWhenPicked(AssistantProviderCatalogue.row(for: "my-proxy")))
        XCTAssertFalse(AssistantPage.turnsOnWhenPicked(AssistantProviderCatalogue.row(for: "openai")))
    }

    /// "None" turns the assistant off without destroying the draft.
    ///
    /// The address, the id and the model are kept, the page presents no service
    /// while it is off, and picking the same endpoint again restores the draft
    /// and waits for the switch.
    func testTurningOffKeepsTheAddressAndTheChoiceCanComeBack() {
        var config = AssistantConfiguration.default
        config.chat = AssistantSettings(
            providerID: "custom",
            model: "my-model",
            baseURL: "https://proxy.example.com/v1"
        )
        config.serviceChosen = true
        config.isSetUp = true

        AssistantPage.choose(nil, in: &config)
        XCTAssertFalse(config.isSetUp)
        XCTAssertEqual(config.serviceChosen, false)
        XCTAssertEqual(config.chat.providerID, "custom", "None destroyed the service")
        XCTAssertEqual(config.chat.model, "my-model", "None destroyed the model")
        XCTAssertEqual(
            config.chat.baseURL,
            "https://proxy.example.com/v1",
            "None destroyed the custom address"
        )
        XCTAssertFalse(AssistantPage.presentsService(config), "None must present no service")

        AssistantPage.choose("custom", in: &config)
        XCTAssertTrue(AssistantPage.presentsService(config))
        XCTAssertEqual(config.chat.baseURL, "https://proxy.example.com/v1")
        XCTAssertFalse(config.isSetUp, "coming back is not the same as being switched on")
        XCTAssertTrue(AssistantPage.canTurnOn(config))
    }

    /// A record turned off opens as None even though its address is still there.
    func testARecordTurnedOffOpensAsNone() throws {
        var config = reported
        config.assistant.serviceChosen = false
        config.assistant.chat.baseURL = "https://proxy.example.com/v1"
        let host = host(config)
        let service = try XCTUnwrap(select("Service", in: host))
        XCTAssertEqual(service.accessibilityValue() as? String, "None")
        XCTAssertNil(select("Model", in: host))
    }

    /// The switch is enabled only for an address a request can be built from.
    func testTheSwitchWaitsForAnAddressThatCanAnswer() {
        var config = AssistantConfiguration.default
        config.chat.providerID = "custom"
        config.serviceChosen = true
        XCTAssertFalse(AssistantPage.canTurnOn(config))
        config.chat.baseURL = "http://api.example.com/v1"
        XCTAssertFalse(AssistantPage.canTurnOn(config), "a remote http address is refused")
        config.chat.baseURL = "http://127.0.0.1:8080/v1"
        XCTAssertTrue(AssistantPage.canTurnOn(config))
    }

    /// A stored "None" outranks the legacy inference; a set-up record outranks
    /// both.
    func testTheStoredChoiceOutranksTheLegacyInference() {
        var config = AssistantConfiguration.default
        config.chat.providerID = "custom"
        XCTAssertNil(config.serviceChosen)
        XCTAssertTrue(AssistantPage.presentsService(config), "a legacy record still finds its service")

        config.serviceChosen = false
        XCTAssertFalse(AssistantPage.presentsService(config))

        config.isSetUp = true
        XCTAssertTrue(AssistantPage.presentsService(config))
    }

    /// A space around a hand-edited id is read once, by every page question.
    func testASpaceAroundTheProviderIDIsTrimmedByThePage() {
        var config = AssistantConfiguration.default
        config.chat.providerID = "  ollama  "
        XCTAssertTrue(AssistantPage.namesService(config))
        XCTAssertEqual(
            AssistantProviderCatalogue.row(for: config.chat.resolvedProviderID).name,
            "Ollama"
        )
    }
}
