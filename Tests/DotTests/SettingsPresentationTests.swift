import AppKit
import DotCore
import SwiftUI
import XCTest

@testable import Dot

/// The settings window as the product now presents it.
///
/// Two capabilities are configurable, speech to text and AI rewrite, so the
/// sidebar offers six pages, the retired Voices and Connectors tabs open AI
/// rewrite, the Shortcuts page has no assistant row, and the AI rewrite page
/// has no answers card. Everything here is data or an offscreen host: no
/// window is ordered, no Keychain is read and no service is asked.
@MainActor
final class SettingsPresentationTests: XCTestCase {
    // MARK: - The sidebar

    /// The pages the sidebar draws, in the order it draws them.
    func testTheSidebarOffersTheSixPagesInOrder() {
        XCTAssertEqual(
            SettingsView.Page.sidebarPages.map(\.title),
            ["General", "Speech to text", "Shortcuts", "Appearance", "AI rewrite", "About"]
        )
        XCTAssertEqual(
            SettingsView.Page.sidebarPages.map(\.rawValue),
            [0, 1, 2, 3, 5, 4],
            "the stored tab numbers did not move"
        )
    }

    /// Neither retired page is offered, and the two renamed pages are not
    /// offered under their old names either.
    ///
    /// The cases and their tab numbers stay, which is what keeps a stored tab
    /// and an old caller working; what the sidebar draws is the filtered list.
    func testTheSidebarDrawsNoRetiredOrRenamedPage() {
        let drawn = Set(SettingsView.Page.sidebarPages.map(\.title))
        for retired in ["Provider", "Assistant", "Voices", "Connectors"] {
            XCTAssertFalse(drawn.contains(retired), "\(retired) is still drawn")
        }
        XCTAssertFalse(SettingsView.Page.voices.isShownInSidebar)
        XCTAssertFalse(SettingsView.Page.connectors.isShownInSidebar)
    }

    /// The enum keeps every case and its raw value, so a stored tab number and
    /// a caller that names one still resolve.
    func testEveryPageKeepsItsStoredTabNumber() {
        XCTAssertEqual(SettingsView.Page.general.rawValue, 0)
        XCTAssertEqual(SettingsView.Page.provider.rawValue, 1)
        XCTAssertEqual(SettingsView.Page.shortcuts.rawValue, 2)
        XCTAssertEqual(SettingsView.Page.appearance.rawValue, 3)
        XCTAssertEqual(SettingsView.Page.about.rawValue, 4)
        XCTAssertEqual(SettingsView.Page.assistant.rawValue, 5)
        XCTAssertEqual(SettingsView.Page.voices.rawValue, 6)
        XCTAssertEqual(SettingsView.Page.connectors.rawValue, 7)
        XCTAssertEqual(SettingsView.Page(rawValue: 6), .voices)
        XCTAssertEqual(SettingsView.Page(rawValue: 7), .connectors)
    }

    /// A caller that still names tab 6 or 7 lands on AI rewrite, never on the
    /// page the sidebar stopped offering.
    func testTheRetiredTabsOpenAIRewrite() {
        XCTAssertEqual(SettingsView.Page(rawValue: 6)?.resolved, .assistant)
        XCTAssertEqual(SettingsView.Page(rawValue: 7)?.resolved, .assistant)
        for page in SettingsView.Page.allCases {
            XCTAssertEqual(
                page.resolved,
                page.resolved.resolved,
                "\(page.title) resolves differently the second time"
            )
            if page.isShownInSidebar {
                XCTAssertEqual(page.resolved, page, "\(page.title) moved off its own tab")
            }
        }
    }

    /// The Shortcuts page lists the three keys Dot registers and no assistant
    /// row, whatever the configuration's assistant key says.
    ///
    /// The page draws this list itself, so a row cannot be on the page without
    /// being in it.
    func testTheShortcutsPageHasNoAssistantRow() {
        XCTAssertEqual(
            SettingsView.ShortcutRow.allCases.map(\.title),
            ["Start and stop recording", "Paste last transcript", "Open dictation palette"]
        )
        for row in SettingsView.ShortcutRow.allCases {
            XCTAssertFalse(
                row.title.localizedCaseInsensitiveContains("assistant"),
                "\(row.title) still mentions the assistant"
            )
        }
    }

    // MARK: - The AI rewrite page

    /// The configured page is the switch and three cards, and no answers.
    func testTheConfiguredPageOffersTheSwitchServiceModelAndStyles() {
        var config = AssistantConfiguration.default
        config.isSetUp = true
        config.chat = AssistantSettings(
            providerID: AssistantProviderID.openCodeGo,
            model: "kimi-k3"
        )

        let cards = AssistantPage.cards(config: config, hasKey: true)
        XCTAssertEqual(cards.map(\.title), ["AI rewrite", "Service", "Model", "Styles"])
        XCTAssertEqual(
            AssistantPage.Card.allCases.map(\.title),
            ["AI rewrite", "Service", "Model", "Styles"]
        )
        XCTAssertFalse(
            AssistantPage.Card.allCases.map(\.title).contains("Answers"),
            "an Answers card came back"
        )
    }

    /// A record that cannot be used is the switch and the service card.
    func testAnUnconfiguredPageOffersTheServiceCardOnly() {
        XCTAssertEqual(
            AssistantPage.cards(config: .default, hasKey: false).map(\.title),
            ["AI rewrite", "Service"]
        )
        XCTAssertEqual(
            AssistantPage.cards(config: .default, hasKey: true).map(\.title),
            ["AI rewrite", "Service"],
            "a stored key alone offered settings for a service that is not set up"
        )

        var unfinished = AssistantConfiguration.default
        unfinished.serviceChosen = true
        unfinished.chat.providerID = AssistantProviderID.openCodeGo
        XCTAssertEqual(
            AssistantPage.cards(config: unfinished, hasKey: false).map(\.title),
            ["AI rewrite", "Service"],
            "a chosen service with no key offered its settings"
        )
    }

    /// A configured page still draws its model and its rewrite controls, and
    /// still has no answer destination.
    func testTheConfiguredPageHostsTheModelAndNoAnswerDestination() throws {
        var config = DotConfig.default
        config.assistant.isSetUp = true
        config.assistant.chat = AssistantSettings(
            providerID: AssistantProviderID.openCodeGo,
            model: "kimi-k3"
        )

        let host = assistantHost(config, keyed: [AssistantProviderID.openCodeGo])
        XCTAssertNotNil(select("Service", in: host), "the configured page lost its service")
        XCTAssertNotNil(select("Model", in: host), "the configured page lost its model")
        XCTAssertNil(
            select("Deliver answers", in: host),
            "the configured page still offers an answer destination"
        )
    }

    /// The not-set-up page still supports choosing a service and adding a key.
    func testTheUnconfiguredPageStillSetsAServiceUp() throws {
        let host = assistantHost(.default)
        XCTAssertNotNil(select("Service", in: host), "the page cannot choose a service")
        let service = try XCTUnwrap(select("Service", in: host))
        XCTAssertEqual(service.accessibilityValue() as? String, "None")
        XCTAssertNil(textField(placeholder: "API key", in: host), "a key was asked of no service")

        var chosen = AssistantConfiguration.default
        chosen.serviceChosen = true
        chosen.chat.providerID = AssistantProviderID.openCodeGo
        var config = DotConfig.default
        config.assistant = chosen

        let keyed = assistantHost(config)
        XCTAssertNotNil(
            textField(placeholder: "API key", in: keyed),
            "a chosen service that needs a key has no key field"
        )
        XCTAssertNil(select("Model", in: keyed), "a model was offered before the service is usable")
    }

    // MARK: - Choosing a service and saving a key

    /// The exact state after a service is picked and its key is saved, without
    /// a Keychain or a network.
    ///
    /// This is the reported path: a person picks OpenCode Go and saves its
    /// subscription key. Before the key, the page asks for it and offers no
    /// model or styles. After it, the record is usable, Rewrite is on with every
    /// built-in style, and the card would offer the chips. A failed connection
    /// check does not undo any of that, and it never claims "Connected".
    func testAKeyTurnsRewritingOnAndAFailedCheckDoesNotUndoIt() {
        let service = AssistantProviderID.openCodeGo
        var config = AssistantConfiguration.default
        XCTAssertFalse(AssistantAvailability.isUsable(config: config, hasKey: false))

        // Picking the row names the service but does not turn it on: its key is
        // the missing piece.
        AssistantPage.choose(service, in: &config)
        XCTAssertEqual(config.chat.resolvedProviderID, service)
        XCTAssertEqual(config.serviceChosen, true)
        XCTAssertFalse(config.isSetUp, "picking a keyed service switched it on")
        XCTAssertFalse(
            AssistantAvailability.isUsable(config: config, hasKey: false),
            "a keyed service with no key was usable"
        )
        XCTAssertEqual(
            AssistantPage.cards(config: config, hasKey: false).map(\.title),
            ["AI rewrite", "Service"]
        )
        XCTAssertEqual(
            AssistantAvailability.readiness(config: config, hasKey: true),
            .notSetUp,
            "a stored key alone is not a choice of rewriting"
        )

        // Saving the key (the page's Connect, or accepting a stored one) is the
        // consent step. It turns rewriting on and keeps the service.
        AssistantPage.turnOn(&config)
        XCTAssertTrue(config.isSetUp)
        XCTAssertEqual(config.serviceChosen, true)
        XCTAssertTrue(
            AssistantAvailability.isUsable(config: config, hasKey: true),
            "the key did not make the service usable"
        )
        XCTAssertEqual(
            AssistantPage.cards(config: config, hasKey: true).map(\.title),
            ["AI rewrite", "Service", "Model", "Styles"],
            "the style controls stay hidden after a key is saved"
        )

        // The rewrite settings are what the card offers after the next take.
        XCTAssertTrue(config.rewrite.enabled, "Offer rewrites is off on a fresh record")
        XCTAssertEqual(config.rewrite.styles, RewriteStyleID.shippedCases)
        XCTAssertFalse(config.rewrite.choices.isEmpty, "there is no style to offer")
        XCTAssertTrue(
            RewriteOffer.shouldOffer(
                rewrite: config.rewrite,
                assistant: config,
                hasKey: true,
                text: "Ship the settings change on Thursday.",
                delivery: .pasted
            ),
            "the island would not offer a style after the key was saved"
        )

        // A check that fails is reported as a failure, and the page keeps its
        // cards: the status row is about the last request, not about readiness.
        var connection = AssistantConnectionState.notSetUp
        connection = AssistantConnectionEvent.availability(isUsable: true).applied(to: connection)
        XCTAssertEqual(connection, .checking, "a usable record starts its check from checking")
        connection = AssistantConnectionEvent.checkStarted.applied(to: connection)
        connection = AssistantConnectionEvent.checkFailed("Rejected the key (401)").applied(to: connection)
        XCTAssertEqual(connection, .notConnected("Rejected the key (401)"))
        XCTAssertFalse(connection == .connected, "a failed check claimed a connection")
        XCTAssertTrue(
            AssistantAvailability.isUsable(config: config, hasKey: true),
            "a failed models request turned the settings off"
        )
        XCTAssertEqual(AssistantPage.cards(config: config, hasKey: true).count, 4)

        // The key's Keychain id is the service id, unchanged by the page rename.
        XCTAssertEqual(CredentialStore.account(for: service), "opencode-go")
        XCTAssertEqual(CredentialStore.serviceName(for: service), "DOT_API_KEY_OPENCODE-GO")
    }

    /// Turning "None" leaves the stored values in the file.
    func testChoosingNoneKeepsTheStoredConfiguration() {
        var config = AssistantConfiguration.default
        config.chat = AssistantSettings(
            providerID: AssistantProviderID.openCodeGo,
            model: "kimi-k3"
        )
        config.serviceChosen = true
        config.isSetUp = true

        AssistantPage.choose(nil, in: &config)
        XCTAssertFalse(config.isSetUp)
        XCTAssertEqual(config.serviceChosen, false)
        XCTAssertEqual(config.chat.providerID, AssistantProviderID.openCodeGo)
        XCTAssertEqual(config.chat.model, "kimi-k3")
    }

    // MARK: - The legacy file

    /// A configuration written before this presentation change still loads,
    /// keeps every value, and round-trips.
    func testALegacyConfigurationRoundTrips() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dot-presentation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // The shape the old pages wrote: the assistant's block with a chosen
        // service, a typed model, a proxy address, answer delivery, the
        // connected-apps switch and a subset of rewrite styles.
        let legacy = #"""
        {
          "provider": "deepgram",
          "assistant": {
            "chat": {
              "provider": "custom",
              "model": "my-model",
              "baseURL": "https://proxy.example.com/v1",
              "temperature": 0.3,
              "maxSteps": 4
            },
            "delivery": "paste-and-speak",
            "actionsEnabled": false,
            "rewrite": {
              "enabled": true,
              "styles": ["concise", "formal"]
            },
            "voice": { "providerID": "elevenlabs", "voiceID": "rachel", "speed": 1.2 },
            "connectors": { "enabled": ["files"], "policies": {} }
          }
        }
        """#
        let url = directory.appendingPathComponent("legacy.json")
        try legacy.write(to: url, atomically: true, encoding: .utf8)
        let config = DotConfig.load(from: url)

        XCTAssertEqual(config.provider, ProviderIdentifier.deepgram)
        XCTAssertEqual(config.assistant.chat.providerID, "custom")
        XCTAssertEqual(config.assistant.chat.model, "my-model")
        XCTAssertEqual(config.assistant.chat.baseURL, "https://proxy.example.com/v1")
        XCTAssertEqual(config.assistant.rewrite.styles, [.concise, .formal])

        // The record presents its service on the renamed page, and the page's
        // cleanup gate does not pretend it is ready without a key.
        XCTAssertTrue(AssistantPage.presentsService(config.assistant))
        XCTAssertEqual(
            AssistantPage.cards(config: config.assistant, hasKey: false).map(\.title),
            ["AI rewrite", "Service"]
        )

        let encoded = try JSONEncoder().encode(config)
        let restored = try JSONDecoder().decode(DotConfig.self, from: encoded)
        XCTAssertEqual(restored, config, "a legacy file lost a value on the way through")
        XCTAssertEqual(restored.assistant.rewrite.styles, [.concise, .formal])
    }

    // MARK: - The master switch

    /// The switch is the first card, and turning it off leaves only itself.
    ///
    /// It is not an eraser: the service, its key, the model, the typed address
    /// and every style are the file's, not the switch's, and turning it back on
    /// has to return the page to the state it left.
    func testTheMasterSwitchGovernsEveryCardBelowIt() {
        var config = AssistantConfiguration.default
        config.isSetUp = true
        config.serviceChosen = true
        config.chat = AssistantSettings(
            providerID: AssistantProviderID.openCodeGo,
            model: "kimi-k3",
            baseURL: "https://proxy.example.com/v1",
            reasoningVariant: "high",
            discoveredModel: DiscoveredModel(
                id: "kimi-k3",
                reasoning: ModelReasoningSupport(efforts: ["low", "high"], toggle: true)
            )
        )
        config.rewrite.custom = [
            CustomRewriteStyle(id: "haiku", title: "Haiku", instruction: "Rewrite as a haiku."),
        ]
        config.rewrite.setInstruction("Write the task as a checklist.", for: .prompt)
        let before = config

        XCTAssertEqual(
            AssistantPage.cards(config: config, hasKey: true).map(\.title),
            ["AI rewrite", "Service", "Model", "Styles"]
        )

        AssistantPage.setRewriting(false, in: &config)
        XCTAssertEqual(
            AssistantPage.cards(config: config, hasKey: true).map(\.title),
            ["AI rewrite"],
            "a page with rewriting off still offered its settings"
        )
        XCTAssertEqual(config.chat, before.chat, "the switch changed the service or its key record")
        XCTAssertEqual(config.serviceChosen, before.serviceChosen)
        XCTAssertEqual(config.isSetUp, before.isSetUp, "the switch turned the assistant off")
        XCTAssertEqual(config.rewrite.styles, before.rewrite.styles)
        XCTAssertEqual(config.rewrite.custom, before.rewrite.custom)
        XCTAssertEqual(config.rewrite.builtInInstructions, before.rewrite.builtInInstructions)
        XCTAssertFalse(config.rewrite.enabled)

        AssistantPage.setRewriting(true, in: &config)
        XCTAssertEqual(config, before, "turning the switch back on restored a different record")
    }

    /// The rendered page draws the switch alone when rewriting is off, and the
    /// service again when it is on.
    func testTheRenderedPageHidesItsCardsWhileRewritingIsOff() throws {
        var config = DotConfig.default
        config.assistant.isSetUp = true
        config.assistant.chat = AssistantSettings(
            providerID: AssistantSettings.defaultProviderID,
            model: "gpt-4o"
        )

        let off = assistantHost(config, keyed: [AssistantSettings.defaultProviderID], rewriting: false)
        XCTAssertNil(select("Service", in: off), "the service was drawn while rewriting is off")
        XCTAssertNil(select("Model", in: off), "the model was drawn while rewriting is off")

        let on = assistantHost(config, keyed: [AssistantSettings.defaultProviderID])
        XCTAssertNotNil(select("Service", in: on), "the service stayed hidden after the switch came on")
        XCTAssertNotNil(select("Model", in: on), "the model stayed hidden after the switch came on")
    }

    // MARK: - The model and its reasoning

    /// The picker offers only what the service published, the id the file
    /// already names and the field for anything else.
    ///
    /// The catalogue shipped model lists once; this is the test that stops one
    /// coming back through a fallback.
    func testTheModelPickerNeverInventsAModel() {
        let empty = AssistantPage.modelOptions(catalog: [], storedModel: "")
        XCTAssertEqual(empty.map(\.title), ["Custom model…"], "an empty catalogue offered a hardcoded model")
        XCTAssertEqual(empty.map(\.value), [AssistantPage.customChoice])

        let stored = AssistantPage.modelOptions(catalog: [], storedModel: "my-model")
        XCTAssertEqual(stored.map(\.title), ["my-model", "Custom model…"])

        let listed = AssistantPage.modelOptions(
            catalog: [DiscoveredModel(id: "alpha"), DiscoveredModel(id: "beta")],
            storedModel: "beta"
        )
        XCTAssertEqual(listed.map(\.title), ["alpha", "beta", "Custom model…"])
        XCTAssertEqual(listed.dropLast().map(\.value), ["alpha", "beta"])
    }

    /// The Reasoning row is drawn for a model that published controls and for
    /// no other.
    func testTheReasoningRowAppearsOnlyForAModelThatPublishesIt() throws {
        var config = DotConfig.default
        config.assistant.isSetUp = true
        config.assistant.chat = AssistantSettings(
            providerID: AssistantSettings.defaultProviderID,
            model: "gpt-4o"
        )
        let key = AssistantSettings.defaultProviderID

        let plain = assistantHost(
            config,
            keyed: [key],
            models: [DiscoveredModel(id: "gpt-4o", name: "GPT-4o")]
        )
        XCTAssertNil(
            select("Reasoning", in: plain),
            "a model that published nothing was offered a reasoning row"
        )

        let published = assistantHost(
            config,
            keyed: [key],
            models: [
                DiscoveredModel(
                    id: "gpt-4o",
                    reasoning: ModelReasoningSupport(
                        efforts: ["low", "high", "max"],
                        toggle: true,
                        defaultEffort: "high"
                    )
                ),
            ]
        )
        XCTAssertNotNil(
            select("Reasoning", in: published),
            "a model that published levels has no reasoning row"
        )
    }

    /// The choices are exactly what the service published, in order.
    func testTheReasoningOptionsAreThePublishedOnes() {
        let full = DiscoveredModel(
            id: "m",
            reasoning: ModelReasoningSupport(
                efforts: ["none", "minimal", "low", "medium", "high", "xhigh", "max"],
                toggle: true,
                defaultEffort: "high"
            )
        )
        let options = AssistantPage.reasoningOptions(for: full, style: .openAICompatible)
        XCTAssertEqual(
            options.map(\.title),
            ["Default (High)", "Off", "None", "Minimal", "Low", "Medium", "High", "Extra high", "Max"]
        )
        XCTAssertEqual(
            options.map(\.value),
            ["", "off", "none", "minimal", "low", "medium", "high", "xhigh", "max"]
        )

        // A toggle with no levels publishes the two states, and only on a
        // shape that can express one.
        let toggleOnly = DiscoveredModel(
            id: "m",
            reasoning: ModelReasoningSupport(toggle: true)
        )
        XCTAssertEqual(
            AssistantPage.reasoningOptions(for: toggleOnly, style: .openAICompatible).map(\.title),
            ["Default", "Off", "On"]
        )
        XCTAssertEqual(
            AssistantPage.reasoningOptions(for: toggleOnly, style: .anthropic).map(\.title),
            ["Default", "Off"],
            "an Anthropic-shaped model that publishes no adaptive mode cannot be switched on"
        )
        let adaptive = DiscoveredModel(
            id: "m",
            reasoning: ModelReasoningSupport(toggle: true, thinkingTypes: ["adaptive"])
        )
        XCTAssertEqual(
            AssistantPage.reasoningOptions(for: adaptive, style: .anthropic).map(\.title),
            ["Default", "Off", "On"]
        )

        // The switch's own two states are not invented for a model that never
        // published them, and a model with nothing to choose gets no row.
        let effortsOnly = DiscoveredModel(
            id: "m",
            reasoning: ModelReasoningSupport(efforts: ["low"], toggle: false)
        )
        XCTAssertEqual(
            AssistantPage.reasoningOptions(for: effortsOnly, style: .openAICompatible).map(\.title),
            ["Default", "Low"]
        )
        XCTAssertTrue(AssistantPage.reasoningOptions(for: nil, style: .openAICompatible).isEmpty)
        XCTAssertTrue(
            AssistantPage.reasoningOptions(
                for: DiscoveredModel(id: "m", reasoning: ModelReasoningSupport()),
                style: .openAICompatible
            ).isEmpty,
            "a model with an empty support block was offered a row"
        )
        XCTAssertEqual(AssistantPage.reasoningLabel("xhigh"), "Extra high")
        XCTAssertEqual(AssistantPage.reasoningLabel("none"), "None")
        XCTAssertEqual(AssistantPage.reasoningLabel("Ultra"), "Ultra")
    }

    // MARK: - A model list that changes the record

    /// A complete list that no longer names the stored model retires its
    /// metadata without replacing the person's model id.
    func testACompleteListDropsTheMetadataOfARetiredModel() {
        let update = AssistantPage.discoveryUpdate(
            storedModel: "retired-model",
            storedDiscovered: DiscoveredModel(
                id: "retired-model",
                reasoning: ModelReasoningSupport(efforts: ["low", "high"])
            ),
            storedVariant: "high",
            models: [DiscoveredModel(id: "new-model")],
            complete: true,
            style: .openAICompatible
        )
        XCTAssertEqual(
            update,
            AssistantPage.DiscoveryUpdate(
                model: "retired-model",
                discoveredModel: nil,
                reasoningVariant: nil
            ),
            "the retired model kept the metadata of a model that no longer exists"
        )
    }

    /// A partial list is not evidence that a model was retired.
    func testAPartialListChangesNoStoredMetadata() {
        XCTAssertNil(
            AssistantPage.discoveryUpdate(
                storedModel: "stored-model",
                storedDiscovered: DiscoveredModel(id: "stored-model"),
                storedVariant: "high",
                models: [DiscoveredModel(id: "first-page-model")],
                complete: false,
                style: .openAICompatible
            ),
            "a list that stopped part way was read as a retirement"
        )
    }

    /// A model the list names gets its discovery stored, and a reasoning level
    /// it no longer publishes is cleared.
    func testAMatchedModelStoresItsDiscoveryAndDropsAnUnpublishedLevel() {
        let discovered = DiscoveredModel(
            id: "m",
            reasoning: ModelReasoningSupport(efforts: ["low", "high"])
        )
        let update = AssistantPage.discoveryUpdate(
            storedModel: "m",
            storedDiscovered: nil,
            storedVariant: "ultra",
            models: [discovered],
            complete: true,
            style: .openAICompatible
        )
        XCTAssertEqual(
            update,
            AssistantPage.DiscoveryUpdate(
                model: "m",
                discoveredModel: discovered,
                reasoningVariant: nil
            )
        )

        let kept = AssistantPage.discoveryUpdate(
            storedModel: "m",
            storedDiscovered: discovered,
            storedVariant: "high",
            models: [discovered],
            complete: true,
            style: .openAICompatible
        )
        XCTAssertNil(kept, "a list that agrees with the file touched it")
    }

    /// A service that lists models and has none stored gets its first one, but
    /// only when the list is complete.
    func testAnEmptyStoredModelTakesTheFirstOnlyFromACompleteList() {
        let models = [DiscoveredModel(id: "first"), DiscoveredModel(id: "second")]
        XCTAssertEqual(
            AssistantPage.discoveryUpdate(
                storedModel: "",
                storedDiscovered: nil,
                storedVariant: nil,
                models: models,
                complete: true,
                style: .openAICompatible
            ),
            AssistantPage.DiscoveryUpdate(
                model: "first",
                discoveredModel: models[0],
                reasoningVariant: nil
            )
        )
        XCTAssertNil(
            AssistantPage.discoveryUpdate(
                storedModel: "",
                storedDiscovered: nil,
                storedVariant: nil,
                models: models,
                complete: false,
                style: .openAICompatible
            )
        )
    }

    // MARK: - The styles card

    /// The pills are the five shipped styles and the person's own, with the dot
    /// each one's state deserves.
    func testTheStyleSelectorShowsTheFiveStylesAndTheCustomOnes() {
        var rewrite = RewriteConfiguration.default
        rewrite.styles = [.prompt, .formal]
        rewrite.custom = [
            CustomRewriteStyle(id: "haiku", title: "Haiku", instruction: "Rewrite as a haiku."),
            CustomRewriteStyle(id: "empty", title: "  ", instruction: ""),
        ]
        let pills = AssistantPage.stylePills(rewrite)
        XCTAssertEqual(
            pills.map(\.title),
            ["Agent prompt", "Concise", "Professional", "Casual", "Gen Z", "Haiku", "Untitled"]
        )
        XCTAssertEqual(
            pills.map(\.selection),
            [
                .builtIn(.prompt), .builtIn(.concise), .builtIn(.formal), .builtIn(.casual),
                .builtIn(.genZ), .custom("haiku"), .custom("empty"),
            ]
        )
        XCTAssertEqual(
            pills.map(\.isOn),
            [true, false, true, false, false, true, false],
            "a pill's dot does not report whether the style is offered"
        )
    }

    /// A removed style is not a pill, and the selection moves to a style the
    /// page still draws.
    func testARemovedStyleLeavesTheRowAndTheSelection() {
        var rewrite = RewriteConfiguration.default
        rewrite.custom = [
            CustomRewriteStyle(id: "haiku", title: "Haiku", instruction: "Rewrite as a haiku."),
        ]
        XCTAssertEqual(
            AssistantPage.resolvedSelection(.builtIn(.casual), rewrite: rewrite),
            .builtIn(.casual)
        )

        rewrite.deleteBuiltIn(.prompt)
        XCTAssertEqual(
            AssistantPage.stylePills(rewrite).map(\.title),
            ["Concise", "Professional", "Casual", "Gen Z", "Haiku"]
        )
        XCTAssertEqual(
            AssistantPage.resolvedSelection(.builtIn(.prompt), rewrite: rewrite),
            .builtIn(.concise),
            "the card stayed on a style the row no longer offers"
        )

        for id in [RewriteStyleID.concise, .formal, .casual, .genZ] {
            rewrite.deleteBuiltIn(id)
        }
        XCTAssertEqual(
            AssistantPage.resolvedSelection(.builtIn(.formal), rewrite: rewrite),
            .custom("haiku"),
            "the card did not fall back to the person's own style"
        )
        rewrite.custom = []
        XCTAssertNil(
            AssistantPage.resolvedSelection(.builtIn(.formal), rewrite: rewrite),
            "a page with no styles kept a selection"
        )
        XCTAssertEqual(
            AssistantPage.emptyStylesMessage,
            "No styles. Use + Add style to create one."
        )
    }

    /// A removed style loses its editor, and the card opens on the first style
    /// that is still there.
    func testDeletingABuiltInStyleRemovesItsControls() throws {
        var config = readyConfig(providerID: AssistantSettings.defaultProviderID, model: "gpt-4o")
        let key = AssistantSettings.defaultProviderID
        let before = assistantHost(config, keyed: [key], style: .builtIn(.concise))
        XCTAssertNotNil(textView(label: "Concise prompt", in: before))

        config.assistant.rewrite.deleteBuiltIn(.concise)
        XCTAssertFalse(
            AssistantPage.stylePills(config.assistant.rewrite).map(\.title).contains("Concise")
        )
        XCTAssertEqual(config.assistant.rewrite.deletedBuiltIns, [.concise])

        let after = assistantHost(config, keyed: [key], style: .builtIn(.concise))
        XCTAssertNil(
            textView(label: "Concise prompt", in: after),
            "the removed style kept its prompt editor"
        )
        XCTAssertNotNil(
            textView(label: "Agent prompt prompt", in: after),
            "the card did not open on the first style still on the page"
        )
    }

    /// A page whose styles were all removed draws no editor and says what to do.
    func testAPageWithEveryStyleRemovedDrawsTheEmptyState() throws {
        var config = readyConfig(providerID: AssistantSettings.defaultProviderID, model: "gpt-4o")
        for id in RewriteStyleID.shippedCases {
            config.assistant.rewrite.deleteBuiltIn(id)
        }
        XCTAssertEqual(config.assistant.rewrite.visibleBuiltIns, [])
        XCTAssertEqual(AssistantPage.stylePills(config.assistant.rewrite), [])

        let host = assistantHost(
            config,
            keyed: [AssistantSettings.defaultProviderID],
            models: [DiscoveredModel(id: "gpt-4o")]
        )
        XCTAssertGreaterThan(host.fittingSize.height, 0, "the page could not be laid out")
        XCTAssertNil(textView(label: "Agent prompt prompt", in: host))
        XCTAssertTrue(textViews(in: host).isEmpty, "a style that is not there was drawn")
    }

    /// The field follows the selected style: its switch and its prompt editor.
    func testTheStylesCardDrawsTheChosenStylesOwnControls() throws {
        var config = readyConfig(providerID: AssistantSettings.defaultProviderID, model: "gpt-4o")
        config.assistant.rewrite.custom = [
            CustomRewriteStyle(id: "haiku", title: "Haiku", instruction: "Rewrite as a haiku."),
        ]

        let prompt = assistantHost(
            config,
            keyed: [AssistantSettings.defaultProviderID],
            style: .builtIn(.prompt)
        )
        XCTAssertNotNil(textView(label: "Agent prompt prompt", in: prompt))
        XCTAssertNil(
            textView(label: "Standing rules", in: prompt),
            "the page drew a standing-rules field with the switch off"
        )

        let concise = assistantHost(
            config,
            keyed: [AssistantSettings.defaultProviderID],
            style: .builtIn(.concise)
        )
        XCTAssertNotNil(textView(label: "Concise prompt", in: concise))
        XCTAssertNil(textView(label: "Agent prompt prompt", in: concise))
        XCTAssertNil(
            textView(label: "Standing rules", in: concise),
            "a style that is not the Agent prompt drew the standing rules"
        )

        let custom = assistantHost(
            config,
            keyed: [AssistantSettings.defaultProviderID],
            style: .custom("haiku")
        )
        XCTAssertEqual(textField(placeholder: "Style name", in: custom)?.stringValue, "Haiku")
        XCTAssertEqual(
            textView(label: "Style instruction", in: custom)?.string,
            "Rewrite as a haiku."
        )
        XCTAssertNil(textView(label: "Standing rules", in: custom))
    }

    /// The agent prompt is one editor, and the rules the model reads are in it.
    ///
    /// The template asks for a task built only from what the speaker said, so
    /// the page offers the text the model is given and nothing that asks the
    /// model for more.
    func testTheAgentPromptDrawsOneEditorAndNoRulesRequest() throws {
        let config = readyConfig(
            providerID: AssistantSettings.defaultProviderID,
            model: "gpt-4o"
        )
        let host = assistantHost(
            config,
            keyed: [AssistantSettings.defaultProviderID],
            style: .builtIn(.prompt)
        )
        let editors = textViews(in: host)
        XCTAssertEqual(
            editors.count,
            1,
            "the agent prompt card drew an editor the switch did not ask for"
        )
        XCTAssertEqual(editors.first?.accessibilityLabel(), "Agent prompt prompt")
        XCTAssertEqual(editors.first?.string, RewriteStyleID.prompt.template)
        XCTAssertTrue(
            editors.first?.string.contains("Add nothing the speaker did not say") == true,
            "the prompt the page edits is not the one that forbids additions"
        )
        XCTAssertNil(textView(label: "Working rules", in: host))
    }

    /// The standing rules are drawn under the Agent prompt's editor, and only
    /// while the switch is on.
    ///
    /// The field is the same editor the prompt uses, six lines tall, and it
    /// shows the text the file holds. The switch writes the stored field, so
    /// the block the next rewrite appends is the block the page shows.
    func testTheStandingRulesFieldFollowsTheSwitch() throws {
        var config = readyConfig(providerID: AssistantSettings.defaultProviderID, model: "gpt-4o")
        config.assistant.rewrite.setStandingRules("## House rules\n- Run the build.")
        config.assistant.rewrite.standingRulesEnabled = false
        XCTAssertNil(
            textView(
                label: AssistantPage.standingRulesTitle,
                in: assistantHost(
                    config,
                    keyed: [AssistantSettings.defaultProviderID],
                    style: .builtIn(.prompt)
                )
            ),
            "the field was drawn with the switch off"
        )

        config.assistant.rewrite.standingRulesEnabled = true
        let on = assistantHost(
            config,
            keyed: [AssistantSettings.defaultProviderID],
            style: .builtIn(.prompt)
        )
        let field = try XCTUnwrap(
            textView(label: AssistantPage.standingRulesTitle, in: on),
            "the field was not drawn with the switch on"
        )
        XCTAssertEqual(field.string, "## House rules\n- Run the build.")
        XCTAssertEqual(
            AssistantPage.standingRulesEditorHeight,
            AssistantPage.promptEditorHeight(lines: 6),
            "the standing rules field is not six lines tall"
        )
        XCTAssertLessThan(AssistantPage.standingRulesEditorHeight, AssistantPage.promptEditorHeight)
        XCTAssertEqual(
            AssistantPage.standingRulesTitle,
            "Standing rules",
            "the switch lost its title"
        )
        XCTAssertEqual(
            AssistantPage.standingRulesHelp,
            "Dot appends these rules to Agent prompts after generation. It doesn’t send them to the model."
        )
    }

    /// An edit to a built-in prompt is stored, and the template itself is not.
    func testEditingTheAgentPromptStoresTheEditAndTheTemplateClearsIt() throws {
        let box = ConfigBox(readyConfig(providerID: AssistantSettings.defaultProviderID, model: "gpt-4o"))
        let host = liveHost(box)
        let editor = try XCTUnwrap(
            textView(label: "Agent prompt prompt", in: host),
            "the agent prompt has no field"
        )
        XCTAssertEqual(
            editor.string,
            RewriteStyleID.prompt.template,
            "an untouched style does not show the shipped prompt"
        )

        editor.selectAll(nil)
        editor.insertText("Write the task as a checklist.", replacementRange: editor.selectedRange())
        pump(host)
        XCTAssertEqual(
            box.config.assistant.rewrite.builtInInstructions["prompt"],
            "Write the task as a checklist."
        )

        editor.selectAll(nil)
        editor.insertText(RewriteStyleID.prompt.template, replacementRange: editor.selectedRange())
        pump(host)
        XCTAssertNil(
            box.config.assistant.rewrite.builtInInstructions["prompt"],
            "typing the shipped template back recorded an edit nobody made"
        )
    }

    /// An edited prompt is what the field shows, and Reset restores the
    /// shipped one without touching another style.
    func testAnEditedPromptIsShownAndResetRestoresTheShippedOne() {
        var config = readyConfig(providerID: AssistantSettings.defaultProviderID, model: "gpt-4o")
        config.assistant.rewrite.setInstruction("Write a checklist.", for: .prompt)
        config.assistant.rewrite.setInstruction("Be brief.", for: .concise)

        let host = assistantHost(
            config,
            keyed: [AssistantSettings.defaultProviderID],
            style: .builtIn(.prompt)
        )
        XCTAssertEqual(
            textView(label: "Agent prompt prompt", in: host)?.string,
            "Write a checklist.",
            "the field does not show the edit the file carries"
        )

        XCTAssertFalse(
            AssistantPage.shouldStoreInstruction(RewriteStyleID.prompt.template, for: .prompt)
        )
        XCTAssertTrue(AssistantPage.shouldStoreInstruction("Write a checklist.", for: .prompt))

        AssistantPage.resetInstruction(for: .prompt, in: &config.assistant.rewrite)
        XCTAssertNil(config.assistant.rewrite.builtInInstructions["prompt"])
        XCTAssertEqual(
            config.assistant.rewrite.instruction(for: .prompt),
            RewriteStyleID.prompt.template
        )
        XCTAssertEqual(
            config.assistant.rewrite.builtInInstructions["concise"],
            "Be brief.",
            "resetting one prompt changed another"
        )
    }

    // MARK: - Explanations on the settings controls

    /// The exact copy behind the changed rows, and the native controls that
    /// carry it in a real host.
    ///
    /// Each picker and editor is mounted the way the rendered fixtures mount
    /// it, then read from its AppKit accessibility and tooltip fields. No
    /// tooltip is hovered, no VoiceOver process is started and no view body is
    /// evaluated outside a host.
    func testTheExplanationCopyIsWiredToEveryChangedRow() throws {
        XCTAssertEqual(
            SettingsExplanation.calibrationHelp,
            "Dot learns this microphone's background noise to set the level meter's floor and the threshold for trimming silence at the ends of a take. Reset clears what it learned; microphone gain is never changed."
        )
        XCTAssertEqual(
            SettingsExplanation.dwellSubtitle,
            "How long results stay on the island."
        )
        XCTAssertEqual(
            SettingsExplanation.dwellHelp,
            "Pasted results close after at most 3.5 seconds. Hovering, scrolling or editing the card pauses the countdown, and a rewrite card stays at least 60 seconds."
        )
        XCTAssertEqual(
            SettingsExplanation.historyHelp,
            "How many recent transcripts Dot keeps in ~/Library/Application Support/Dot/history.json. Older ones are removed from that file."
        )
        XCTAssertEqual(
            SettingsExplanation.formatHelp,
            "Dot formats pasted text for the app where you started dictating. History keeps the original transcript."
        )
        XCTAssertEqual(
            SettingsExplanation.segmentSubtitle,
            "Longer recordings are sent in parts of this length."
        )
        XCTAssertEqual(
            SettingsExplanation.segmentHelp,
            "Service default uses the longest stretch the service accepts, and a longer choice is capped at that limit."
        )
        XCTAssertEqual(
            SettingsExplanation.temperatureHelp,
            "Lower values keep the transcript literal and consistent; higher values let the model vary its wording."
        )
        XCTAssertEqual(
            SettingsExplanation.authHelp,
            "How the API key is sent: as an Authorization: Bearer header or as an api-key header."
        )
        XCTAssertEqual(
            SettingsExplanation.regionHelp,
            "The Azure region your Speech resource was created in. A key works only in its own region."
        )
        XCTAssertEqual(
            SettingsExplanation.planHelp,
            "Token Plan keys start with tp- or ttp- and use the Token Plan address. Pasting one selects this plan."
        )
        XCTAssertEqual(
            SettingsExplanation.reasoningHelp,
            "How much the model reasons before the assistant answers. Rewrites ask for the lightest level the model publishes."
        )
        XCTAssertEqual(
            SettingsExplanation.standingRulesHelp,
            "Dot appends these rules to Agent prompts after generation. It doesn’t send them to the model."
        )
        XCTAssertEqual(SettingsExplanation.calibrationNone, "Not learned yet.")
        XCTAssertEqual(SettingsExplanation.calibrationOne, "Learned from 1 recording.")
        XCTAssertEqual(SettingsView.calibrationObservedText(0), "Not learned yet.")
        XCTAssertEqual(SettingsView.calibrationObservedText(1), "Learned from 1 recording.")
        XCTAssertEqual(SettingsView.calibrationObservedText(14), "Learned from 14 recordings.")
        XCTAssertEqual(SettingsView.calibrationObservedText(998), "Learned from 998 recordings.")
        XCTAssertEqual(SettingsView.calibrationObservedText(999), "Learned from 999 or more recordings.")

        let planRow = AssistantProviderCatalogue.row(for: AssistantProviderID.xiaomi)
        let planAddress = planRow.plans.first { $0.id == "token-plan" }?.baseURL?.absoluteString
        var planConfig = DotConfig.default
        planConfig.assistant.isSetUp = true
        planConfig.assistant.chat = AssistantSettings(providerID: planRow.id, model: "chat-model")
        planConfig.assistant.chat.baseURL = planAddress
        let planHost = assistantHost(
            planConfig,
            keyed: [planRow.id],
            models: [DiscoveredModel(id: "chat-model")],
            connection: .connected
        )
        let planSelects = selects("Plan", in: planHost)
        XCTAssertEqual(planSelects.count, 1, "the Plan row has \(planSelects.count) native targets")
        let planSelect = try XCTUnwrap(planSelects.first, "the Plan picker has no native target")
        XCTAssertEqual(planSelect.accessibilityValue() as? String, "Token Plan")
        XCTAssertEqual(planSelect.accessibilityHelp(), SettingsExplanation.planHelp)
        XCTAssertNil(planSelect.toolTip)

        var reasoningConfig = DotConfig.default
        reasoningConfig.assistant.isSetUp = true
        reasoningConfig.assistant.chat = AssistantSettings(
            providerID: AssistantSettings.defaultProviderID,
            model: "gpt-4o"
        )
        let reasoningHost = assistantHost(
            reasoningConfig,
            keyed: [AssistantSettings.defaultProviderID],
            models: [
                DiscoveredModel(
                    id: "gpt-4o",
                    name: "GPT-4o",
                    reasoning: ModelReasoningSupport(
                        efforts: ["low", "high", "max"],
                        toggle: true,
                        defaultEffort: "high"
                    )
                ),
            ],
            connection: .connected
        )
        let reasoningSelects = selects("Reasoning", in: reasoningHost)
        XCTAssertEqual(
            reasoningSelects.count,
            1,
            "the Reasoning row has \(reasoningSelects.count) native targets"
        )
        let reasoningSelect = try XCTUnwrap(
            reasoningSelects.first,
            "the Reasoning picker has no native target"
        )
        XCTAssertEqual(reasoningSelect.accessibilityValue() as? String, "Default (High)")
        XCTAssertEqual(reasoningSelect.accessibilityHelp(), SettingsExplanation.reasoningHelp)
        XCTAssertNil(reasoningSelect.toolTip)

        let general = settingsHost(tab: 0, config: .default)
        let historyPicker = try XCTUnwrap(
            select("Transcripts to keep", in: general),
            "the history picker lost its native accessibility element"
        )
        XCTAssertEqual(historyPicker.accessibilityHelp(), SettingsExplanation.historyHelp)
        XCTAssertNil(historyPicker.toolTip)

        var assistant = DotConfig.default
        assistant.assistant.isSetUp = true
        assistant.assistant.rewrite.standingRulesEnabled = true
        assistant.assistant.rewrite.setStandingRules("## House rules\n- Run the build.")
        let rewrite = assistantHost(
            assistant,
            keyed: [AssistantSettings.defaultProviderID],
            models: [DiscoveredModel(id: "gpt-4o")],
            style: .builtIn(.prompt)
        )
        let editor = try XCTUnwrap(
            textView(label: AssistantPage.standingRulesTitle, in: rewrite),
            "the standing rules editor was not drawn"
        )
        XCTAssertEqual(AssistantPage.standingRulesHelp, SettingsExplanation.standingRulesHelp)
        XCTAssertEqual(editor.accessibilityHelp(), SettingsExplanation.standingRulesHelp)
        XCTAssertNil(editor.toolTip)
        XCTAssertTrue(editor.isEditable, "the explained editor lost its editing")
        XCTAssertTrue(editor.isSelectable, "the explained editor lost its selection")
    }

    func testGeneralPickersExposeTheirExplanationsAsNativeHelp() throws {
        let general = settingsHost(tab: 0, config: .default)
        for (label, help) in [
            ("Recording mode", SettingsExplanation.recordingModeSubtitle),
            ("Microphone", SettingsExplanation.microphoneSubtitle),
        ] {
            let picker = try XCTUnwrap(select(label, in: general))
            XCTAssertNil(picker.toolTip, label)
            XCTAssertEqual(picker.accessibilityHelp(), help, label)
        }
    }

    /// The retention picker is drawn inside Output: below Recording mode and
    /// above Microphone, the first rows of the sections either side of it.
    func testTheRetentionPickerSitsInTheOutputSection() throws {
        let general = settingsHost(tab: 0, config: .default)
        func top(_ label: String) throws -> CGFloat {
            let element = try XCTUnwrap(select(label, in: general), "\(label) was not drawn")
            let frame = element.convert(element.bounds, to: general)
            return general.isFlipped ? frame.minY : general.bounds.height - frame.maxY
        }
        let recording = try top("Recording mode")
        let retention = try top("Transcripts to keep")
        let microphone = try top("Microphone")
        XCTAssertLessThan(recording, retention, "retention moved above Recording mode")
        XCTAssertLessThan(retention, microphone, "retention moved below the Microphone section")
    }

    private func settingsHost(tab: Int, config: DotConfig) -> NSHostingView<AnyView> {
        let store = ConfigStore(config: config)
        let view = SettingsView(
            store: store,
            providers: MenuBuilder.providerRows(config: config) { _ in false },
            tab: tab,
            onChange: {},
            onSetAPIKey: { _, _ in nil },
            onChangeShortcut: {},
            credentials: SpeechCredentialChecks(),
            allowsOffscreenChecks: false
        )
        let host = NSHostingView(rootView: AnyView(view.environment(\.settingsHeadless, true)))
        host.frame = NSRect(x: 0, y: 0, width: 820, height: 900)
        for _ in 0 ..< 3 {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return host
    }

    // MARK: - Hosts

    /// A configured record the card tests start from.
    private func readyConfig(providerID: String, model: String) -> DotConfig {
        var config = DotConfig.default
        config.assistant.isSetUp = true
        config.assistant.chat = AssistantSettings(providerID: providerID, model: model)
        return config
    }

    /// A record a live host can write back to.
    ///
    /// The page and the binding it holds are main-actor only; the unchecked
    /// conformance is what lets the binding's `@Sendable` closures write to the
    /// box without a second copy of the record.
    private final class ConfigBox: @unchecked Sendable {
        var config: DotConfig

        init(_ config: DotConfig) {
            self.config = config
        }

        var binding: Binding<DotConfig> {
            Binding(get: { self.config }, set: { self.config = $0 })
        }
    }

    private func assistantHost(
        _ config: DotConfig,
        keyed: Set<String> = [],
        models: [DiscoveredModel]? = nil,
        style: AssistantPage.StyleSelection? = nil,
        rewriting: Bool = true,
        connection: AssistantConnectionState = .notSetUp
    ) -> NSHostingView<AnyView> {
        var config = config
        config.assistant.rewrite.enabled = rewriting
        let page = AssistantPage(
            config: .constant(config),
            onChange: {},
            onSetKey: { _, _ in nil },
            onDeleteKey: { _ in nil }
        )
        .environment(\.settingsHeadless, true)
        .environment(\.assistantKeyedProviders, keyed)
        .environment(\.assistantConnectionPreview, connection)
        .environment(\.assistantDiscoveredModelsPreview, models)
        .environment(\.assistantStyleSelectionPreview, style)
        let host = NSHostingView(rootView: AnyView(page))
        host.frame = NSRect(x: 0, y: 0, width: 640, height: 900)
        for _ in 0 ..< 3 {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return host
    }

    /// A host whose page writes into a box, so an edit made in a field can be
    /// read back without a window or a file.
    private func liveHost(_ box: ConfigBox) -> NSHostingView<AnyView> {
        let page = AssistantPage(
            config: box.binding,
            onChange: {},
            onSetKey: { _, _ in nil },
            onDeleteKey: { _ in nil }
        )
        .environment(\.settingsHeadless, true)
        .environment(\.assistantKeyedProviders, [AssistantSettings.defaultProviderID])
        .environment(\.assistantConnectionPreview, .notSetUp)
        .environment(\.assistantDiscoveredModelsPreview, [DiscoveredModel(id: "gpt-4o")])
        .environment(\.assistantStyleSelectionPreview, AssistantPage.StyleSelection.builtIn(.prompt))
        let host = NSHostingView(rootView: AnyView(page))
        host.frame = NSRect(x: 0, y: 0, width: 640, height: 900)
        for _ in 0 ..< 3 {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return host
    }

    /// Lays the page out again after a field changed, without ordering a window.
    private func pump(_ host: NSView) {
        for _ in 0 ..< 3 {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }

    // MARK: - Reading what a headless host draws

    private func select(_ label: String, in view: NSView?) -> DotSelectAccessibilityView? {
        selects(label, in: view).first
    }

    private func selects(_ label: String, in view: NSView?) -> [DotSelectAccessibilityView] {
        guard let view else { return [] }
        var found: [DotSelectAccessibilityView] = []
        if let element = view as? DotSelectAccessibilityView, element.accessibilityLabel() == label {
            found.append(element)
        }
        for sub in view.subviews {
            found += selects(label, in: sub)
        }
        return found
    }

    /// Every editor's text view under a host.
    private func textViews(in view: NSView?) -> [NSTextView] {
        guard let view else { return [] }
        if let scrollView = view as? DotTextEditorScrollView,
           let textView = scrollView.documentView as? NSTextView {
            return [textView]
        }
        return view.subviews.flatMap(textViews(in:))
    }

    /// The editor's text view with an accessible name, wherever it is drawn.
    private func textView(label: String, in view: NSView?) -> NSTextView? {
        guard let view else { return nil }
        if let textView = view as? NSTextView, textView.accessibilityLabel() == label {
            return textView
        }
        for sub in view.subviews {
            if let found = textView(label: label, in: sub) { return found }
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
}
