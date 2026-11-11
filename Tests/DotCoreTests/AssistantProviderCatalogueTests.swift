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
