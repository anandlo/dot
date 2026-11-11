import XCTest

@testable import DotCore

/// Which base URLs Dot will send audio and a key to.
///
/// A base URL is typed by hand, and the request that follows carries the audio
/// and the API key. Over plain HTTP both travel in clear text, so a remote
/// endpoint is refused and a server on the machine itself is not.
final class EndpointPolicyTests: XCTestCase {
    private func url(_ string: String) -> URL {
        URL(string: string)!
    }

    func testAnHTTPSAddressIsAccepted() {
        XCTAssertNil(EndpointPolicy.validate(url("https://api.openai.com/v1")))
        XCTAssertNil(EndpointPolicy.validate(url("https://api.groq.com/openai/v1")))
    }

    func testAPlainHTTPRemoteAddressIsRefused() {
        guard case .cleartextHost(let host)? = EndpointPolicy.validate(url("http://api.openai.com/v1")) else {
            return XCTFail("a remote http endpoint was accepted")
        }
        XCTAssertEqual(host, "api.openai.com")
    }

    func testPlainHTTPIsAcceptedForTheMachineItself() {
        for address in [
            "http://127.0.0.1:8765/v1",
            "http://localhost:1234/v1",
            "http://127.0.0.10/v1",
            "http://[::1]:8080/v1",
        ] {
            XCTAssertNil(EndpointPolicy.validate(url(address)), address)
        }
    }

    func testANameThatMerelyEndsInLocalhostIsNotVouchedFor() {
        XCTAssertFalse(EndpointPolicy.isLoopback("notlocalhost"))
        XCTAssertFalse(EndpointPolicy.isLoopback("localhost.example.com"))
        XCTAssertFalse(EndpointPolicy.isLoopback("10.0.0.1"))
    }

    func testAnAddressThatIsNotHTTPAtAllIsRefused() {
        guard case .unsupportedScheme("file")? = EndpointPolicy.validate(url("file:///etc/passwd")) else {
            return XCTFail("a file URL was accepted as an endpoint")
        }
        guard case .notAnAddress? = EndpointPolicy.validate(url("api.openai.com/v1")) else {
            return XCTFail("an address with no scheme was accepted")
        }
    }

    func testAnEmptyValueIsNotAnAddress() {
        XCTAssertThrowsError(try EndpointPolicy.url(from: "   "))
    }

    func testTheTypedAddressIsTrimmed() throws {
        let parsed = try EndpointPolicy.url(from: "  https://api.openai.com/v1  ")
        XCTAssertEqual(parsed.absoluteString, "https://api.openai.com/v1")
    }

    // MARK: - The factory

    func testTheFactoryRefusesAPlainHTTPRemoteEndpoint() {
        for id in [
            ProviderIdentifier.openAI,
            ProviderIdentifier.groq,
            ProviderIdentifier.deepgram,
            ProviderIdentifier.elevenLabs,
            ProviderIdentifier.azure,
            ProviderIdentifier.xiaomi,
        ] {
            var config = DotConfig.default
            config.providers[id] = ProviderConfig(baseURL: "http://speech.example.com/v1")
            XCTAssertThrowsError(try ProviderRegistry.makeProvider(id: id, config: config)) { error in
                guard case .refusedEndpoint(let refused, _)? = error as? ProviderRegistryError else {
                    return XCTFail("\(id): expected a refused endpoint, got \(error)")
                }
                XCTAssertEqual(refused, id)
            }
        }
    }

    func testTheFactoryAcceptsAServerOnTheMachineItself() throws {
        var config = DotConfig.default
        config.providers[ProviderIdentifier.openAI] = ProviderConfig(baseURL: "http://127.0.0.1:8765/v1")

        let provider = try ProviderRegistry.makeProvider(
            id: ProviderIdentifier.openAI,
            config: config,
            credentials: .empty
        )
        XCTAssertEqual(provider.id, ProviderIdentifier.openAI)
    }

    func testTheFactoryStillRefusesAMissingEndpoint() {
        var config = DotConfig.default
        config.providers[ProviderIdentifier.openAI] = ProviderConfig(baseURL: nil)
        XCTAssertThrowsError(try ProviderRegistry.makeProvider(id: ProviderIdentifier.openAI, config: config)) { error in
            guard case .missingBaseURL? = error as? ProviderRegistryError else {
                return XCTFail("expected a missing endpoint, got \(error)")
            }
        }
    }
}
