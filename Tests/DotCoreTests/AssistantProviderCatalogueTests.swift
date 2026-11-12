import XCTest

@testable import DotCore

/// The row table the Settings picker and the factory read.
final class AssistantProviderCatalogueTests: XCTestCase {
    func testTheDefaultProviderHasARow() {
        XCTAssertNotNil(
            AssistantProviderCatalogue.shippedRow(for: AssistantSettings.defaultProviderID),
            "a fresh configuration must point at a provider the catalogue knows"
        )
    }

    func testTheSpeechVendorsReuseTheirSpeechID() {
        XCTAssertNotNil(AssistantProviderCatalogue.shippedRow(for: ProviderIdentifier.openAI))
        XCTAssertNotNil(AssistantProviderCatalogue.shippedRow(for: ProviderIdentifier.groq))
        XCTAssertTrue(AssistantProviderCatalogue.row(for: ProviderIdentifier.openAI).requiresKey)
    }

    func testAnUnknownIDBehavesLikeACustomEndpoint() {
        let row = AssistantProviderCatalogue.row(for: "my-proxy")
        XCTAssertEqual(row.id, "my-proxy")
        XCTAssertEqual(row.style, .openAICompatible)
        XCTAssertNil(row.defaultBaseURL)
        XCTAssertFalse(row.requiresKey)
        XCTAssertEqual(AssistantProviderCatalogue.row(for: "").id, "custom")
    }

    func testEveryRowShipsAnAcceptedAddressAndAPath() {
        for row in AssistantProviderCatalogue.rows {
            XCTAssertFalse(row.path.isEmpty, "\(row.id) has no path")
            XCTAssertTrue(row.path.hasPrefix("/") == false, "\(row.id) has a leading slash")
            if let url = row.defaultBaseURL {
                XCTAssertNil(
                    EndpointPolicy.validate(url),
                    "\(row.id) ships an address the endpoint policy refuses"
                )
            }
        }
    }

    func testARowThatNeedsAKeyRefusesToBuildWithoutOne() {
        let settings = AssistantSettings(providerID: "anthropic", model: "claude-test")
        XCTAssertThrowsError(
            try AssistantProviderCatalogue.makeProvider(settings: settings, apiKey: nil)
        ) { error in
            guard case ProviderError.missingCredential = error else {
                return XCTFail("expected missingCredential, got \(error)")
            }
        }
    }

    func testALocalRowBuildsWithoutAKey() throws {
        let settings = AssistantSettings(providerID: "ollama", model: "llama3.2")
        let provider = try AssistantProviderCatalogue.makeProvider(settings: settings, apiKey: nil)
        XCTAssertTrue(provider is OpenAIChatProvider)
    }

    func testTheAnthropicRowBuildsAnAnthropicProvider() throws {
        let settings = AssistantSettings(providerID: "anthropic", model: "claude-test")
        let provider = try AssistantProviderCatalogue.makeProvider(settings: settings, apiKey: "key")
        XCTAssertTrue(provider is AnthropicChatProvider)
    }

    func testTheShapeCanBeOverriddenForACustomEndpoint() throws {
        var settings = AssistantSettings(providerID: "custom", model: "local-model")
        settings.baseURL = "http://127.0.0.1:1234"
        settings.apiStyle = .anthropic
        let provider = try AssistantProviderCatalogue.makeProvider(settings: settings, apiKey: nil)
        XCTAssertTrue(provider is AnthropicChatProvider)
    }

    func testATypedCleartextRemoteAddressIsRefused() {
        var settings = AssistantSettings(providerID: "custom", model: "local-model")
        settings.baseURL = "http://example.com/v1"
        XCTAssertThrowsError(
            try AssistantProviderCatalogue.makeProvider(settings: settings, apiKey: nil)
        ) { error in
            guard let rejection = error as? EndpointPolicy.Rejection,
                  case .cleartextHost = rejection
            else {
                return XCTFail("expected a refused cleartext address, got \(error)")
            }
        }
    }

    func testTheModelFallsBackToTheRowsSuggestion() {
        var settings = AssistantSettings(providerID: "openai", model: "")
        XCTAssertEqual(AssistantProviderCatalogue.model(for: settings), "gpt-4o-mini")
        settings.model = "my-model"
        XCTAssertEqual(AssistantProviderCatalogue.model(for: settings), "my-model")
    }

    func testTheStepCapIsAppliedBeforeTheTurnStarts() {
        var settings = AssistantSettings(providerID: "ollama", model: "m", maxSteps: 99)
        settings.maxSteps = 99
        XCTAssertEqual(settings.sanitized().maxSteps, AssistantSettings.maximumSteps)
    }

    func testALegacyAzureDeploymentURLGetsAnAPIVersion() throws {
        var settings = AssistantSettings(providerID: "azure-openai", model: "gpt-4o")
        settings.baseURL = "https://my-resource.openai.azure.com/openai/deployments/my-deploy"
        let provider = try XCTUnwrap(
            try AssistantProviderCatalogue.makeProvider(settings: settings, apiKey: "key")
                as? OpenAIChatProvider
        )
        XCTAssertEqual(
            provider.chatURL.absoluteString,
            "https://my-resource.openai.azure.com/openai/deployments/my-deploy/chat/completions"
                + "?api-version=\(AssistantProviderCatalogue.legacyAzureAPIVersion)"
        )
        XCTAssertEqual(provider.authStyle, .apiKey, "Azure reads its key from api-key")
    }

    func testTheV1AzureFormGetsNoAPIVersion() throws {
        var settings = AssistantSettings(providerID: "azure-openai", model: "gpt-4o")
        settings.baseURL = "https://my-resource.openai.azure.com/openai/v1"
        let provider = try XCTUnwrap(
            try AssistantProviderCatalogue.makeProvider(settings: settings, apiKey: "key")
                as? OpenAIChatProvider
        )
        XCTAssertEqual(
            provider.chatURL.absoluteString,
            "https://my-resource.openai.azure.com/openai/v1/chat/completions"
        )
    }

    func testTheAddedVendorsShipTheirEndpointsBeforeCustom() throws {
        let ids = AssistantProviderCatalogue.rows.map(\.id)
        let custom = try XCTUnwrap(ids.firstIndex(of: AssistantProviderCatalogue.customRow.id))
        let opencode = try XCTUnwrap(ids.firstIndex(of: "opencode-go"))
        let xiaomi = try XCTUnwrap(ids.firstIndex(of: "xiaomi"))
        XCTAssertLessThan(opencode, custom, "OpenCode Go sits before Custom")
        XCTAssertLessThan(xiaomi, custom, "Xiaomi sits before Custom")
        XCTAssertLessThan(opencode, xiaomi, "the two rows are in alphabetical order")

        let opencodeRow = AssistantProviderCatalogue.row(for: "opencode-go")
        XCTAssertEqual(opencodeRow.name, "OpenCode Go")
        XCTAssertEqual(
            opencodeRow.defaultBaseURL?.absoluteString,
            "https://opencode.ai/inference/go/openai/v1"
        )
        XCTAssertEqual(opencodeRow.defaultModels.first, "deepseek-v4.1-flash")
        XCTAssertTrue(opencodeRow.requiresKey)
        XCTAssertEqual(opencodeRow.keyNote, "Uses your OpenCode Go subscription key.")

        let xiaomiRow = AssistantProviderCatalogue.row(for: "xiaomi")
        XCTAssertEqual(xiaomiRow.defaultBaseURL?.absoluteString, "https://api.xiaomimimo.com/v1")
        XCTAssertEqual(xiaomiRow.defaultModels, ["mimo-v2.6-flash", "mimo-v2.6-pro"])
        XCTAssertTrue(xiaomiRow.requiresKey)
        XCTAssertEqual(
            CredentialStore.serviceName(for: xiaomiRow.id),
            CredentialStore.serviceName(for: ProviderIdentifier.xiaomi),
            "the chat row reuses the speech item"
        )
    }

    func testTheSubscriptionPlanIsReadFromTheAddressAndFromTheKey() throws {
        let row = AssistantProviderCatalogue.row(for: "xiaomi")
        let standard = AssistantSettings(providerID: "xiaomi", model: "")
        XCTAssertEqual(AssistantProviderCatalogue.plan(for: standard, row: row)?.id, "pay-as-you-go")

        let tokenPlan = try XCTUnwrap(row.plans.first { $0.id == "token-plan" })
        var moved = standard
        moved.baseURL = tokenPlan.baseURL?.absoluteString
        XCTAssertEqual(AssistantProviderCatalogue.plan(for: moved, row: row)?.id, "token-plan")
        XCTAssertEqual(
            try AssistantProviderCatalogue.resolvedBaseURL(settings: moved, row: row)?.absoluteString,
            "https://token-plan-cn.xiaomimimo.com/v1"
        )

        // A key that belongs to the other plan names it, so the page can move
        // the address when one is pasted under the wrong one.
        XCTAssertEqual(AssistantProviderCatalogue.plan(impliedByKey: "tp-abc123", row: row)?.id, "token-plan")
        XCTAssertEqual(AssistantProviderCatalogue.plan(impliedByKey: "ttp-abc123", row: row)?.id, "token-plan")
        XCTAssertNil(AssistantProviderCatalogue.plan(impliedByKey: "sk-abc123", row: row))
        XCTAssertNil(AssistantProviderCatalogue.plan(impliedByKey: "", row: row))
        XCTAssertEqual(row.plans.first?.baseURL, nil, "the row's own address is the default plan")
    }

    func testASubscriptionKeyPastedUnderTheWrongPlanMovesTheAddress() throws {
        let row = AssistantProviderCatalogue.row(for: "xiaomi")
        let standard = AssistantSettings(providerID: "xiaomi", model: "")

        let moved = try XCTUnwrap(
            AssistantProviderCatalogue.movedPlan(forStoredKey: "tp-abc123", settings: standard, row: row)
        )
        XCTAssertEqual(moved.id, "token-plan")
        XCTAssertEqual(
            moved.baseURL?.absoluteString,
            "https://token-plan-cn.xiaomimimo.com/v1",
            "the request follows the key to the host that hands it out"
        )

        // A key of the plan already in use, or one that names no plan, leaves
        // the address exactly as the person set it.
        var onPlan = standard
        onPlan.baseURL = moved.baseURL?.absoluteString
        XCTAssertNil(AssistantProviderCatalogue.movedPlan(forStoredKey: "tp-abc123", settings: onPlan, row: row))
        XCTAssertNil(AssistantProviderCatalogue.movedPlan(forStoredKey: "sk-abc123", settings: standard, row: row))
    }

    func testTheResponsesOnlyModelsAreNeverOffered() {
        let row = AssistantProviderCatalogue.row(for: "opencode-go")
        let listed = [
            "deepseek-v4.1-flash", "glm-5.3", "grok-4-fast", "gpt-5-mini",
            "muse-spark-1", "kimi-k3",
        ]
        let offered = listed.filter { id in
            !row.excludedModelPrefixes.contains { id.hasPrefix($0) }
        }
        XCTAssertEqual(offered, ["deepseek-v4.1-flash", "glm-5.3", "kimi-k3"])
        for id in ["grok-4-fast", "gpt-5-mini", "muse-spark-1"] {
            XCTAssertTrue(
                row.excludedModelPrefixes.contains { id.hasPrefix($0) },
                "\(id) would be offered on a shape this build does not speak"
            )
        }
    }

    func testTheModelsRequestIsTheOneTheCheckSends() throws {
        let secret = "sk-test-0123456789abcdef"
        let openAI = try AssistantModelCatalog.makeRequest(
            settings: AssistantSettings(providerID: "opencode-go"),
            apiKey: secret
        )
        XCTAssertEqual(openAI.httpMethod, "GET")
        XCTAssertEqual(
            openAI.url?.absoluteString,
            "https://opencode.ai/inference/go/openai/v1/models"
        )
        XCTAssertEqual(openAI.value(forHTTPHeaderField: "Authorization"), "Bearer \(secret)")

        let anthropic = try AssistantModelCatalog.makeRequest(
            settings: AssistantSettings(providerID: "anthropic"),
            apiKey: secret
        )
        XCTAssertEqual(anthropic.url?.absoluteString, "https://api.anthropic.com/v1/models")
        XCTAssertEqual(anthropic.value(forHTTPHeaderField: "x-api-key"), secret)
    }

    func testAModelListIsReadInTheOrderTheServiceWroteIt() {
        let body = Data(##"{"data":[{"id":"z-model"},{"id":"a-model"},{"id":"z-model"},{"id":"grok-4"}]}"##.utf8)
        XCTAssertEqual(
            AssistantModelCatalog.models(in: body, excluding: ["grok-"]),
            ["z-model", "a-model"]
        )
        XCTAssertEqual(AssistantModelCatalog.models(in: Data("not json".utf8), excluding: []), [])
        XCTAssertEqual(AssistantModelCatalog.path(for: .openAICompatible), "models")
        XCTAssertEqual(AssistantModelCatalog.path(for: .anthropic), "v1/models")
    }

    func testAModelListIsFetchedFromTheService() async throws {
        let server = try StubServer(responses: [
            StubServer.Response(status: 200, json: ##"{"data":[{"id":"glm-5.3"},{"id":"grok-4"}]}"##),
        ])
        let base = try AssistantTestSupport.loopbackURL(server)
        let fetched = await AssistantModelCatalog.fetch(
            settings: AssistantSettings(providerID: "opencode-go", baseURL: base.absoluteString),
            apiKey: "sk-test",
            session: AssistantTestSupport.session()
        )
        XCTAssertEqual(fetched, ["glm-5.3"], "the excluded ids are dropped from the live list")
        XCTAssertEqual(server.requests.first?.path, "/v1/models")
    }

    func testARewriteTurnsTheVendorsReasoningOffAndAnAnswerDoesNot() throws {
        let settings = AssistantSettings(providerID: "xiaomi", model: "mimo-v2.6-flash")
        let secret = "sk-test"
        let rewrite = try XCTUnwrap(
            try AssistantProviderCatalogue.makeProvider(
                settings: settings,
                apiKey: secret,
                forRewrite: true
            ) as? OpenAIChatProvider
        )
        let rewriteBody = AssistantTestSupport.json(
            try rewrite.makeRequest(messages: [.user("hi")], tools: [], model: "m").httpBody
        )
        XCTAssertEqual(
            (rewriteBody["thinking"] as? [String: Any])?["type"] as? String,
            "disabled",
            "a rewrite waits for no reasoning pass"
        )

        let answer = try XCTUnwrap(
            try AssistantProviderCatalogue.makeProvider(settings: settings, apiKey: secret)
                as? OpenAIChatProvider
        )
        let answerBody = AssistantTestSupport.json(
            try answer.makeRequest(messages: [.user("hi")], tools: [], model: "m").httpBody
        )
        XCTAssertNil(answerBody["thinking"], "the assistant keeps the provider default")
    }

    func testASharedVendorReadsOneKeychainItem() {
        XCTAssertEqual(
            CredentialStore.serviceName(for: AssistantProviderCatalogue.row(for: "openai").id),
            CredentialStore.serviceName(for: ProviderIdentifier.openAI)
        )
        XCTAssertEqual(
            CredentialStore.serviceName(for: AssistantProviderCatalogue.row(for: "groq").id),
            CredentialStore.serviceName(for: ProviderIdentifier.groq)
        )
    }
}
