import XCTest

@testable import DotCore

/// The shape of a request follows the endpoint the configuration points at, not
/// the provider id it was stored under.
///
/// A configuration written by an earlier build can select a provider id the
/// picker no longer offers. The Settings page presents such a configuration as
/// the user's own endpoint, named by the URL it points at, so the request has
/// to match that promise: an endpoint that was pointed somewhere else must not
/// go on speaking the retired service's shape.
final class StoredEndpointShapeTests: XCTestCase {
    func testAStoredEndpointStillPointingAtItsOwnServiceKeepsItsShape() throws {
        let stored = configuration(
            provider: ProviderIdentifier.xiaomi,
            baseURL: "https://api.xiaomimimo.com/v1"
        )
        let provider = try ProviderRegistry.selectedProvider(config: stored, credentials: .empty)

        XCTAssertFalse(ProviderRegistry.isGenericEndpoint(config: stored))
        XCTAssertTrue(provider is XiaomiASRProvider)
        XCTAssertEqual(provider.id, ProviderIdentifier.xiaomi)
    }

    func testARepointedStoredEndpointSpeaksTheOpenAIShape() async throws {
        let server = try StubServer(responses: [
            .init(status: 200, json: #"{"text": "the transcript"}"#),
        ])
        let stored = configuration(
            provider: ProviderIdentifier.xiaomi,
            baseURL: "http://127.0.0.1:\(server.port)/v1"
        )
        let provider = try ProviderRegistry.selectedProvider(config: stored, credentials: .empty)

        XCTAssertTrue(ProviderRegistry.isGenericEndpoint(config: stored))
        let transcript = try await provider.transcribe(wav: makeWAV(), model: nil, language: nil)
        XCTAssertEqual(transcript, "the transcript")

        let request = try XCTUnwrap(server.requests.first)
        XCTAssertEqual(request.path, "/v1/audio/transcriptions")
        XCTAssertTrue(
            request.header("Content-Type")?.hasPrefix("multipart/form-data; boundary=") == true,
            "a repointed endpoint has to be called like every other custom endpoint"
        )
        XCTAssertEqual(
            provider.id,
            ProviderIdentifier.xiaomi,
            "the configuration still selects this id, so the provider has to answer to it"
        )
    }

    func testARepointedEndpointUsesTheHeaderTheConfigurationNames() async throws {
        let server = try StubServer(responses: [
            .init(status: 200, json: #"{"text": "the transcript"}"#),
        ])
        var stored = configuration(
            provider: ProviderIdentifier.xiaomi,
            baseURL: "http://127.0.0.1:\(server.port)/v1"
        )
        stored.providers[ProviderIdentifier.xiaomi]?.authStyle = .apiKey
        let cache = CredentialCache(reader: { _ in .key("secret-key") }, logsReads: false)

        let provider = try ProviderRegistry.selectedProvider(config: stored, credentials: cache)
        _ = try await provider.transcribe(wav: makeWAV(), model: nil, language: nil)

        let request = try XCTUnwrap(server.requests.first)
        XCTAssertEqual(request.header("api-key"), "secret-key")
        XCTAssertNil(request.header("Authorization"), "a repointed endpoint reads its own auth style")
    }

    func testTheAuthControlAppearsExactlyWhenARequestReadsIt() throws {
        // The page shows the header control from the same question the factory
        // answers, so the control and the request cannot disagree.
        let cases: [(name: String, config: DotConfig)] = [
            ("openai", configuration(provider: ProviderIdentifier.openAI, baseURL: nil)),
            (
                "a stored service at its own URL",
                configuration(
                    provider: ProviderIdentifier.xiaomi,
                    baseURL: "https://api.xiaomimimo.com/v1"
                )
            ),
            (
                "a stored service pointed elsewhere",
                configuration(
                    provider: ProviderIdentifier.xiaomi,
                    baseURL: "http://127.0.0.1:8080/v1"
                )
            ),
            ("on device", configuration(provider: ProviderIdentifier.apple, baseURL: nil)),
        ]

        for entry in cases {
            let provider = try? ProviderRegistry.selectedProvider(config: entry.config, credentials: .empty)
            XCTAssertEqual(
                ProviderRegistry.isGenericEndpoint(config: entry.config),
                provider is OpenAICompatibleProvider,
                "\(entry.name) answers two different questions"
            )
        }
    }

    // MARK: - Helpers

    private func makeWAV() -> Data {
        WAVWriter.encode(samples: [0, 100, -100, 1_000, -1_000])
    }

    private func configuration(provider: String, baseURL: String?) -> DotConfig {
        var config = DotConfig.default
        config.provider = provider
        if let baseURL {
            config.providers[provider] = ProviderConfig(baseURL: baseURL)
        }
        return config
    }
}
