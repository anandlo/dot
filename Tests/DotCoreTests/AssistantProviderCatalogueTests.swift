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
            if let url = row.modelsURL {
                XCTAssertNil(
                    EndpointPolicy.validate(url),
                    "\(row.id) ships a models address the endpoint policy refuses"
                )
            }
        }
    }

    /// No shipped row suggests a model any more.
    ///
    /// A frozen suggestion goes stale between builds, and offering one a
    /// service has retired is what a live list exists to prevent. The property
    /// stays on the row for the callers that read it.
    func testNoShippedRowFreezesASuggestion() {
        for row in AssistantProviderCatalogue.rows {
            XCTAssertEqual(row.defaultModels, [], "\(row.id) still ships a model suggestion")
        }
        XCTAssertEqual(AssistantProviderCatalogue.customRow.defaultModels, [])
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

    /// A model is the one the record names. There is no suggestion to fall back
    /// on, so an empty record resolves to an empty model and the provider says
    /// what to do about it.
    func testAModelIsTheOneTheRecordNames() {
        var settings = AssistantSettings(providerID: "openai", model: "")
        XCTAssertEqual(AssistantProviderCatalogue.model(for: settings), "")
        settings.model = " my-model "
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
        XCTAssertEqual(
            opencodeRow.modelsURL?.absoluteString,
            "https://opencode.ai/inference/go/v1/models",
            "the subscription lists its models at the plan's own address"
        )
        XCTAssertNil(opencodeRow.keyNote, "the subscription needs no line under the key row")
        XCTAssertEqual(opencodeRow.defaultModels, [])
        XCTAssertTrue(opencodeRow.requiresKey)

        let xiaomiRow = AssistantProviderCatalogue.row(for: "xiaomi")
        XCTAssertEqual(xiaomiRow.defaultBaseURL?.absoluteString, "https://api.xiaomimimo.com/v1")
        XCTAssertNil(xiaomiRow.modelsURL, "a vendor whose list lives under its base URL names none")
        XCTAssertEqual(xiaomiRow.defaultModels, [])
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
            "https://opencode.ai/inference/go/v1/models",
            "the subscription's catalogue sits beside its inference, not under it"
        )
        XCTAssertEqual(openAI.value(forHTTPHeaderField: "Authorization"), "Bearer \(secret)")

        let anthropic = try AssistantModelCatalog.makeRequest(
            settings: AssistantSettings(providerID: "anthropic"),
            apiKey: secret
        )
        XCTAssertEqual(anthropic.url?.absoluteString, "https://api.anthropic.com/v1/models")
        XCTAssertEqual(anthropic.value(forHTTPHeaderField: "x-api-key"), secret)
    }

    func testATypedAddressCarriesTheModelsPath() throws {
        var settings = AssistantSettings(providerID: "opencode-go")
        settings.baseURL = "https://proxy.example.com/v1"
        let request = try AssistantModelCatalog.makeRequest(settings: settings, apiKey: "key")
        XCTAssertEqual(
            request.url?.absoluteString,
            "https://proxy.example.com/v1/models",
            "a typed address is where the service is, so the list is read there"
        )
    }

    func testTheModelsRequestCarriesTheRowsHeaders() throws {
        let request = try AssistantModelCatalog.makeRequest(
            settings: AssistantSettings(providerID: "openrouter"),
            apiKey: "key"
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "HTTP-Referer"), "https://dot.mac")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-OpenRouter-Title"), "Dot")
    }

    func testALegacyAzureModelsRequestCarriesItsVersion() throws {
        var settings = AssistantSettings(providerID: "azure-openai")
        settings.baseURL = "https://my-resource.openai.azure.com/openai/deployments/my-deploy"
        let request = try AssistantModelCatalog.makeRequest(settings: settings, apiKey: "key")
        XCTAssertEqual(
            request.url?.absoluteString,
            "https://my-resource.openai.azure.com/openai/deployments/my-deploy/models"
                + "?api-version=\(AssistantProviderCatalogue.legacyAzureAPIVersion)"
        )
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

    // MARK: - A discovered route

    private func discovered(
        id: String = "claude-haiku-5-5",
        style: AssistantAPIStyle = .anthropic,
        baseURL: String = "https://opencode.ai/inference/go/anthropic/v1",
        reasoning: ModelReasoningSupport? = nil,
        supportsTemperature: Bool? = nil
    ) -> DiscoveredModel {
        DiscoveredModel(
            id: id,
            name: nil,
            reasoning: reasoning,
            route: ModelAPIRoute(style: style, baseURL: URL(string: baseURL)!),
            supportsTemperature: supportsTemperature
        )
    }

    func testADiscoveredRouteMovesTheRequestToItsOwnAddressAndPath() throws {
        var settings = AssistantSettings(
            providerID: "opencode-go",
            model: "claude-haiku-5-5"
        )
        settings.discoveredModel = discovered()
        let provider = try XCTUnwrap(
            try AssistantProviderCatalogue.makeProvider(settings: settings, apiKey: "key")
                as? AnthropicChatProvider
        )
        let request = try provider.makeRequest(messages: [.user("hi")], tools: [], model: "m")
        XCTAssertEqual(
            request.url?.absoluteString,
            "https://opencode.ai/inference/go/anthropic/v1/messages",
            "a messages model is posted to the messages path, not the row's completions path"
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "key")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "anthropic-version"),
            AnthropicChatProvider.defaultVersion
        )
        XCTAssertEqual(
            request.value(forHTTPHeaderField: AssistantSessionHeader.openCodeGo.rawValue)?.hasPrefix("ses_"),
            true,
            "the subscription needs its session header on every shape"
        )
    }

    func testADiscoveredCompletionsRouteKeepsTheCompletionsPath() throws {
        var settings = AssistantSettings(providerID: "opencode-go", model: "qwen3.8-flash")
        settings.discoveredModel = discovered(
            id: "qwen3.8-flash",
            style: .openAICompatible,
            baseURL: "https://opencode.ai/inference/go/openai/v1"
        )
        let provider = try XCTUnwrap(
            try AssistantProviderCatalogue.makeProvider(settings: settings, apiKey: "key")
                as? OpenAIChatProvider
        )
        XCTAssertEqual(
            provider.chatURL.absoluteString,
            "https://opencode.ai/inference/go/openai/v1/chat/completions"
        )
        XCTAssertNotNil(provider.sessionID)
    }

    /// A route is metadata from the service, and the request carries the key:
    /// an address on a host the row does not ship is never used.
    func testARouteOnAStrangersHostIsIgnored() throws {
        for untrusted in [
            "https://evil.example/v1",
            "https://opencode.ai.evil.example/inference/go/openai/v1",
            "https://user:pass@opencode.ai/inference/go/openai/v1",
        ] {
            var settings = AssistantSettings(providerID: "opencode-go", model: "glm-5.3")
            settings.discoveredModel = discovered(
                id: "glm-5.3",
                style: .openAICompatible,
                baseURL: untrusted
            )
            let provider = try XCTUnwrap(
                try AssistantProviderCatalogue.makeProvider(settings: settings, apiKey: "secret")
                    as? OpenAIChatProvider
            )
            let request = try provider.makeRequest(messages: [.user("hi")], tools: [], model: "m")
            XCTAssertEqual(request.url?.host, "opencode.ai", untrusted)
            XCTAssertEqual(
                request.url?.path,
                "/inference/go/openai/v1/chat/completions",
                "an untrusted route moved the request: \(untrusted)"
            )
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Authorization"),
                "Bearer secret",
                "the key was not sent to the row's own host"
            )
        }
    }

    /// A typed Anthropic address that already ends in `v1` is not asked for
    /// the version twice.
    func testAnAnthropicBaseThatAlreadyEndsInV1IsNotDoubled() throws {
        let settings = AssistantSettings(
            providerID: "anthropic",
            model: "claude-test",
            baseURL: "https://api.anthropic.com/v1"
        )
        let provider = try XCTUnwrap(
            try AssistantProviderCatalogue.makeProvider(settings: settings, apiKey: "key")
                as? AnthropicChatProvider
        )
        XCTAssertEqual(
            provider.messagesURL.absoluteString,
            "https://api.anthropic.com/v1/messages"
        )
    }

    func testATypedAddressOrShapeWinsOverADiscoveredRoute() throws {
        var typedAddress = AssistantSettings(providerID: "opencode-go", model: "claude-haiku-5-5")
        typedAddress.baseURL = "https://proxy.example.com/v1"
        typedAddress.discoveredModel = discovered()
        let proxied = try XCTUnwrap(
            try AssistantProviderCatalogue.makeProvider(settings: typedAddress, apiKey: "key")
                as? OpenAIChatProvider
        )
        XCTAssertEqual(
            proxied.chatURL.absoluteString,
            "https://proxy.example.com/v1/chat/completions",
            "a person who typed an address did not ask for the model's own"
        )

        var typedShape = AssistantSettings(providerID: "opencode-go", model: "claude-haiku-5-5")
        typedShape.apiStyle = .openAICompatible
        typedShape.discoveredModel = discovered()
        let shaped = try XCTUnwrap(
            try AssistantProviderCatalogue.makeProvider(settings: typedShape, apiKey: "key")
                as? OpenAIChatProvider
        )
        XCTAssertEqual(
            shaped.chatURL.absoluteString,
            "https://opencode.ai/inference/go/openai/v1/chat/completions",
            "a typed shape is a decision of the person's"
        )
    }

    func testADiscoveryForAnotherModelIsIgnored() throws {
        var settings = AssistantSettings(providerID: "opencode-go", model: "glm-5.3")
        settings.discoveredModel = discovered()
        let provider = try XCTUnwrap(
            try AssistantProviderCatalogue.makeProvider(settings: settings, apiKey: "key")
                as? OpenAIChatProvider
        )
        XCTAssertEqual(
            provider.chatURL.absoluteString,
            "https://opencode.ai/inference/go/openai/v1/chat/completions"
        )
    }

    func testAModelThatRejectsATemperatureIsSentNone() throws {
        var settings = AssistantSettings(providerID: "openai", model: "gpt-6-luna", temperature: 0.7)
        settings.discoveredModel = DiscoveredModel(
            id: "gpt-6-luna",
            supportsTemperature: false
        )
        let provider = try XCTUnwrap(
            try AssistantProviderCatalogue.makeProvider(settings: settings, apiKey: "key")
                as? OpenAIChatProvider
        )
        XCTAssertNil(provider.temperature)
        let body = AssistantTestSupport.json(
            try provider.makeRequest(messages: [.user("hi")], tools: [], model: "m").httpBody
        )
        XCTAssertNil(body["temperature"], "a model that published no temperature rejects the member")
    }

    func testAModelThatAcceptsATemperatureIsSentTheStoredOne() throws {
        var settings = AssistantSettings(providerID: "openai", model: "gpt-4o", temperature: 0.7)
        settings.discoveredModel = DiscoveredModel(id: "gpt-4o", supportsTemperature: true)
        let provider = try XCTUnwrap(
            try AssistantProviderCatalogue.makeProvider(settings: settings, apiKey: "key")
                as? OpenAIChatProvider
        )
        XCTAssertEqual(provider.temperature, 0.7)
    }

    // MARK: - A reasoning choice

    private func body(of provider: any ChatProvider) throws -> [String: Any] {
        guard let openAI = provider as? OpenAIChatProvider else {
            XCTFail("expected an OpenAI-shaped provider")
            return [:]
        }
        return AssistantTestSupport.json(
            try openAI.makeRequest(messages: [.user("hi")], tools: [], model: "m").httpBody
        )
    }

    private func anthropicBody(of provider: any ChatProvider) throws -> [String: Any] {
        guard let anthropic = provider as? AnthropicChatProvider else {
            XCTFail("expected an Anthropic-shaped provider")
            return [:]
        }
        return AssistantTestSupport.json(
            try anthropic.makeRequest(messages: [.user("hi")], tools: [], model: "m").httpBody
        )
    }

    func testAReasoningChoiceIsSentAsTheMemberItsServiceReads() throws {
        var settings = AssistantSettings(
            providerID: "openai",
            model: "gpt-6-luna",
            reasoningVariant: "high"
        )
        settings.discoveredModel = DiscoveredModel(
            id: "gpt-6-luna",
            reasoning: ModelReasoningSupport(efforts: ["low", "medium", "high"])
        )
        let sent = try body(of: try AssistantProviderCatalogue.makeProvider(settings: settings, apiKey: "key"))
        XCTAssertEqual(sent["reasoning_effort"] as? String, "high")
    }

    func testReasoningCanBeTurnedOffAndOnWhenTheModelPublishesAToggle() throws {
        var off = AssistantSettings(providerID: "openai", model: "gpt-6-luna", reasoningVariant: "off")
        off.discoveredModel = DiscoveredModel(
            id: "gpt-6-luna",
            reasoning: ModelReasoningSupport(toggle: true)
        )
        let offBody = try body(of: try AssistantProviderCatalogue.makeProvider(settings: off, apiKey: "key"))
        XCTAssertEqual((offBody["thinking"] as? [String: Any])?["type"] as? String, "disabled")

        var on = off
        on.reasoningVariant = "on"
        let onBody = try body(of: try AssistantProviderCatalogue.makeProvider(settings: on, apiKey: "key"))
        XCTAssertEqual((onBody["thinking"] as? [String: Any])?["type"] as? String, "enabled")
    }

    func testOffIsNotSentWhereTheModelPublishesNoSwitch() throws {
        var settings = AssistantSettings(
            providerID: "openai",
            model: "gpt-6-luna",
            reasoningVariant: "off"
        )
        settings.discoveredModel = DiscoveredModel(
            id: "gpt-6-luna",
            reasoning: ModelReasoningSupport(efforts: ["low", "high"])
        )
        let sent = try body(of: try AssistantProviderCatalogue.makeProvider(settings: settings, apiKey: "key"))
        XCTAssertNil(sent["thinking"], "a model that publishes no switch is not sent one")
    }

    /// A choice the model never published is not sent.
    ///
    /// A hand-edited file can name any string. It becomes an effort the
    /// service never documented, and the request is refused there, so the
    /// choice is dropped before the request is built.
    func testAnUnpublishedEffortIsNotSent() throws {
        var settings = AssistantSettings(
            providerID: "openai",
            model: "gpt-6-luna",
            reasoningVariant: "ultra"
        )
        settings.discoveredModel = DiscoveredModel(
            id: "gpt-6-luna",
            reasoning: ModelReasoningSupport(efforts: ["low", "high"])
        )
        let sent = try body(of: try AssistantProviderCatalogue.makeProvider(settings: settings, apiKey: "key"))
        XCTAssertNil(sent["reasoning_effort"], "an effort the model never published was sent")
    }

    /// A variant with no discovery belongs to no model, so it is not sent.
    func testAVariantWithNoDiscoveryIsNotSent() throws {
        for variant in ["high", "off", "on"] {
            let settings = AssistantSettings(
                providerID: "openai",
                model: "gpt-6-luna",
                reasoningVariant: variant
            )
            let sent = try body(
                of: try AssistantProviderCatalogue.makeProvider(settings: settings, apiKey: "key")
            )
            XCTAssertNil(sent["reasoning_effort"], variant)
            XCTAssertNil(sent["thinking"], variant)
        }
    }

    /// Turning reasoning on is only sent when the model publishes a switch.
    func testOnIsNotSentWhereTheModelPublishesNoSwitch() throws {
        var settings = AssistantSettings(
            providerID: "openai",
            model: "gpt-6-luna",
            reasoningVariant: "on"
        )
        settings.discoveredModel = DiscoveredModel(
            id: "gpt-6-luna",
            reasoning: ModelReasoningSupport(efforts: ["low", "high"])
        )
        let sent = try body(of: try AssistantProviderCatalogue.makeProvider(settings: settings, apiKey: "key"))
        XCTAssertNil(sent["thinking"], "a model that publishes no switch is not sent one")
    }

    func testOpenRouterTakesItsEffortInsideItsOwnObject() throws {
        var settings = AssistantSettings(
            providerID: "openrouter",
            model: "openai/gpt-6-luna",
            reasoningVariant: "medium"
        )
        settings.discoveredModel = DiscoveredModel(
            id: "openai/gpt-6-luna",
            reasoning: ModelReasoningSupport(efforts: ["low", "medium", "high"])
        )
        let sent = try body(of: try AssistantProviderCatalogue.makeProvider(settings: settings, apiKey: "key"))
        XCTAssertEqual((sent["reasoning"] as? [String: Any])?["effort"] as? String, "medium")
        XCTAssertNil(sent["reasoning_effort"], "OpenRouter reads the object, not the flat member")
    }

    func testAnthropicSendsAnEffortAndTheAdaptiveModeWhenItIsPublished() throws {
        var settings = AssistantSettings(
            providerID: "anthropic",
            model: "claude-test",
            reasoningVariant: "high"
        )
        settings.discoveredModel = DiscoveredModel(
            id: "claude-test",
            reasoning: ModelReasoningSupport(
                efforts: ["low", "medium", "high"],
                thinkingTypes: ["adaptive"]
            )
        )
        let sent = try anthropicBody(
            of: try AssistantProviderCatalogue.makeProvider(settings: settings, apiKey: "key")
        )
        XCTAssertEqual((sent["output_config"] as? [String: Any])?["effort"] as? String, "high")
        XCTAssertEqual((sent["thinking"] as? [String: Any])?["type"] as? String, "adaptive")
    }

    func testAnthropicTurnsThinkingOffOnRequest() throws {
        var settings = AssistantSettings(
            providerID: "anthropic",
            model: "claude-test",
            reasoningVariant: "off"
        )
        settings.discoveredModel = DiscoveredModel(
            id: "claude-test",
            reasoning: ModelReasoningSupport(toggle: true)
        )
        let sent = try anthropicBody(
            of: try AssistantProviderCatalogue.makeProvider(settings: settings, apiKey: "key")
        )
        XCTAssertEqual((sent["thinking"] as? [String: Any])?["type"] as? String, "disabled")
    }

    func testAChosenVariantReplacesTheRewritesOwnSwitch() throws {
        var settings = AssistantSettings(
            providerID: "xiaomi",
            model: "mimo-v2.6-flash",
            reasoningVariant: "low"
        )
        settings.discoveredModel = DiscoveredModel(
            id: "mimo-v2.6-flash",
            reasoning: ModelReasoningSupport(efforts: ["low", "high"])
        )
        let sent = try body(
            of: try AssistantProviderCatalogue.makeProvider(
                settings: settings,
                apiKey: "key",
                forRewrite: true
            )
        )
        XCTAssertEqual(sent["reasoning_effort"] as? String, "low")
    }

    func testARewriteWithNoVariantKeepsTheRowsOwnSwitch() throws {
        let settings = AssistantSettings(providerID: "xiaomi", model: "mimo-v2.6-flash")
        let sent = try body(
            of: try AssistantProviderCatalogue.makeProvider(
                settings: settings,
                apiKey: "key",
                forRewrite: true
            )
        )
        XCTAssertEqual((sent["thinking"] as? [String: Any])?["type"] as? String, "disabled")
    }

    /// A rewrite asks for the lightest effort the model publishes.
    ///
    /// The Go subscription's `deepseek-v4.1-flash` lists `low`, `high` and `max`
    /// and publishes no switch, so a rewrite stored as `high` reasoned through
    /// the whole first-token deadline and came back with nothing. The rewrite
    /// now asks for `low`, and the answer still asks for the level the person
    /// chose.
    func testARewriteAsksForTheLightestEffortTheModelPublishes() throws {
        var settings = AssistantSettings(
            providerID: "opencode-go",
            model: "deepseek-v4.1-flash",
            reasoningVariant: "high"
        )
        settings.discoveredModel = DiscoveredModel(
            id: "deepseek-v4.1-flash",
            reasoning: ModelReasoningSupport(efforts: ["low", "high", "max"])
        )
        let rewrite = try body(
            of: try AssistantProviderCatalogue.makeProvider(
                settings: settings,
                apiKey: "key",
                forRewrite: true
            )
        )
        XCTAssertEqual(rewrite["reasoning_effort"] as? String, "low")
        let answer = try body(
            of: try AssistantProviderCatalogue.makeProvider(settings: settings, apiKey: "key")
        )
        XCTAssertEqual(answer["reasoning_effort"] as? String, "high")
    }

    /// A model that publishes a switch is asked for no reasoning in a rewrite.
    func testARewriteOnASwitchableModelTurnsReasoningOff() throws {
        var settings = AssistantSettings(
            providerID: "openai",
            model: "gpt-6-luna",
            reasoningVariant: "high"
        )
        settings.discoveredModel = DiscoveredModel(
            id: "gpt-6-luna",
            reasoning: ModelReasoningSupport(efforts: ["low", "high"], toggle: true)
        )
        let sent = try body(
            of: try AssistantProviderCatalogue.makeProvider(
                settings: settings,
                apiKey: "key",
                forRewrite: true
            )
        )
        XCTAssertEqual((sent["thinking"] as? [String: Any])?["type"] as? String, "disabled")
        XCTAssertNil(sent["reasoning_effort"], "a rewrite asked for an effort beside the switch")
    }

    /// A model that publishes no reasoning control is sent no reasoning member.
    func testARewriteOnAModelWithNoReasoningSendsNoMember() throws {
        var settings = AssistantSettings(
            providerID: "opencode-go",
            model: "glm-5.3",
            reasoningVariant: "high"
        )
        settings.discoveredModel = DiscoveredModel(id: "glm-5.3")
        let sent = try body(
            of: try AssistantProviderCatalogue.makeProvider(
                settings: settings,
                apiKey: "key",
                forRewrite: true
            )
        )
        XCTAssertNil(sent["reasoning_effort"])
        XCTAssertNil(sent["reasoning"])
        XCTAssertNil(sent["thinking"])
    }

    /// A row's own rewrite switch survives a discovery that publishes no
    /// reasoning, and is still sent beside it.
    func testARewriteKeepsTheRowsOwnSwitchWhenTheModelPublishesNoReasoning() throws {
        var settings = AssistantSettings(providerID: "xiaomi", model: "mimo-v2.6-flash")
        settings.discoveredModel = DiscoveredModel(id: "mimo-v2.6-flash")
        let sent = try body(
            of: try AssistantProviderCatalogue.makeProvider(
                settings: settings,
                apiKey: "key",
                forRewrite: true
            )
        )
        XCTAssertEqual((sent["thinking"] as? [String: Any])?["type"] as? String, "disabled")
        XCTAssertNil(sent["reasoning_effort"])
    }

    /// The lightest level wins whatever order the service listed its levels in,
    /// and a level this build does not know is not a level to ask for.
    func testTheRewriteVariantIsTheLightestPublishedLevel() {
        let listed = DiscoveredModel(
            id: "m",
            reasoning: ModelReasoningSupport(efforts: ["max", "high", "minimal"])
        )
        XCTAssertEqual(AssistantProviderCatalogue.rewriteReasoningVariant(for: listed), "minimal")
        XCTAssertNil(
            AssistantProviderCatalogue.rewriteReasoningVariant(for: DiscoveredModel(id: "m")),
            "a model that publishes no control has no level to ask for"
        )
        XCTAssertNil(
            AssistantProviderCatalogue.rewriteReasoningVariant(
                for: DiscoveredModel(id: "m", reasoning: ModelReasoningSupport(efforts: ["ultra"]))
            ),
            "an effort this build does not know was asked for"
        )
        XCTAssertEqual(
            AssistantProviderCatalogue.rewriteReasoningVariant(
                for: DiscoveredModel(id: "m", reasoning: ModelReasoningSupport(toggle: true))
            ),
            "off"
        )
    }
}
