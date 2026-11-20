import XCTest

@testable import DotCore

/// The four states of the Assistant page's status row, and the one rule behind
/// them.
///
/// The bug these cover: a chat key is the speech provider's Keychain item, so a
/// stored key said "Connected" to a person who had never chosen an assistant
/// service. The status row is now reached from a request, and every gate in the
/// app asks the same question.
final class AssistantConnectionTests: XCTestCase {
    private let key = "sk-test-0123456789abcdef"

    private func settings(_ providerID: String, baseURL: String? = nil) -> AssistantSettings {
        AssistantSettings(providerID: providerID, model: "test-model", baseURL: baseURL)
    }

    // MARK: - The states

    func testTheWordsOnTheStatusRow() {
        XCTAssertEqual(AssistantConnectionState.notSetUp.title, "Not set up")
        XCTAssertEqual(AssistantConnectionState.checking.title, "Checking...")
        XCTAssertEqual(AssistantConnectionState.connected.title, "Connected")
        XCTAssertEqual(AssistantConnectionState.notConnected("").title, "Couldn't connect")
    }

    func testOnlyAFailureCarriesADetail() {
        XCTAssertNil(AssistantConnectionState.notSetUp.detail)
        XCTAssertNil(AssistantConnectionState.checking.detail)
        XCTAssertNil(AssistantConnectionState.connected.detail)
        XCTAssertEqual(AssistantConnectionState.notConnected("Rejected the key (401)").detail,
                       "Rejected the key (401)")
        XCTAssertNil(AssistantConnectionState.notConnected("").detail)
    }

    // MARK: - The reducer

    /// Every state the row can be in, and what each event makes of it.
    func testEveryTransitionOfTheReducer() {
        let events: [AssistantConnectionEvent] = [
            .availability(isUsable: false),
            .availability(isUsable: true),
            .checkStarted,
            .checkSucceeded,
            .checkFailed("Rejected the key (401)"),
        ]
        let refusal = AssistantConnectionState.notConnected("Rejected the key (401)")
        let table: [(state: AssistantConnectionState, results: [AssistantConnectionState])] = [
            (.notSetUp, [.notSetUp, .checking, .notSetUp, .notSetUp, .notSetUp]),
            (.checking, [.notSetUp, .checking, .checking, .connected, refusal]),
            (.connected, [.notSetUp, .connected, .checking, .connected, refusal]),
            (refusal, [.notSetUp, refusal, .checking, .connected, refusal]),
        ]
        for row in table {
            for (event, result) in zip(events, row.results) {
                XCTAssertEqual(
                    event.applied(to: row.state),
                    result,
                    "\(event) on \(row.state)"
                )
            }
        }
    }

    func testNotSetUpAbsorbsALateAnswer() {
        // The person turned the assistant off while a check was in flight: the
        // green dot may not arrive after the page said there is nothing to use.
        let off = AssistantConnectionEvent.availability(isUsable: false).applied(to: .checking)
        XCTAssertEqual(off, .notSetUp)
        XCTAssertEqual(AssistantConnectionEvent.checkSucceeded.applied(to: off), .notSetUp)
    }

    // MARK: - The rule

    func testASpeechKeyAloneIsNotUsable() {
        // The state the bug was reported in: a key stored by the speech page,
        // and an assistant block this build wrote.
        let config = AssistantConfiguration.default
        XCTAssertFalse(config.isSetUp)
        XCTAssertFalse(AssistantAvailability.isUsable(config: config, hasKey: true))
        XCTAssertFalse(AssistantAvailability.isUsable(config: config, hasKey: false))
    }

    func testASetUpServiceIsUsableOnlyWithWhatItNeeds() {
        var config = AssistantConfiguration.default
        config.isSetUp = true
        config.chat.providerID = "anthropic"
        XCTAssertTrue(AssistantAvailability.isUsable(config: config, hasKey: true))
        XCTAssertFalse(AssistantAvailability.isUsable(config: config, hasKey: false))

        // A service on this Mac asks for no key, so it is usable as soon as the
        // person points the assistant at it.
        config.chat.providerID = "ollama"
        XCTAssertTrue(AssistantAvailability.isUsable(config: config, hasKey: false))

        // A hand-filled endpoint is the same case: the row requires no key, and
        // an address is what it is missing.
        config.chat.providerID = "my-proxy"
        config.chat.baseURL = "https://proxy.example.com/v1"
        XCTAssertTrue(AssistantAvailability.isUsable(config: config, hasKey: false))
    }

    /// The state the report was made in: set up on paper, a custom endpoint, no
    /// address stored.
    ///
    /// The old rule returned `true` here, so the chips were offered and every
    /// rewrite then failed in the provider factory. The address is part of what
    /// makes a turn possible, not a detail a request can fill in.
    func testACustomEndpointWithoutAnAddressIsNotUsable() {
        var config = AssistantConfiguration.default
        config.isSetUp = true
        config.chat.providerID = "custom"
        let readiness = AssistantAvailability.readiness(config: config, hasKey: false)
        XCTAssertEqual(readiness, .missingAddress)
        XCTAssertFalse(AssistantAvailability.isUsable(config: config, hasKey: false))
        XCTAssertFalse(AssistantAvailability.isUsable(config: config, hasKey: true))
        XCTAssertEqual(readiness.message, "Add the address this service is reached at.")
    }

    func testTheAddressARowShipsIsEnoughEvenWithNoTypedOne() {
        // Ollama and LM Studio ship a loopback address. The rule may not treat
        // "no typed address" as "no address" for them.
        for id in ["ollama", "lmstudio"] {
            var config = AssistantConfiguration.default
            config.isSetUp = true
            config.chat.providerID = id
            XCTAssertTrue(
                AssistantAvailability.isUsable(config: config, hasKey: false),
                "\(id) should be usable at its shipped address"
            )
            XCTAssertNil(AssistantAvailability.readiness(config: config, hasKey: false).message)
        }
    }

    func testAnAddressThePolicyRefusesIsNotUsable() {
        var config = AssistantConfiguration.default
        config.isSetUp = true
        config.chat.providerID = "custom"
        config.chat.baseURL = "http://api.example.com/v1"
        let readiness = AssistantAvailability.readiness(config: config, hasKey: false)
        XCTAssertEqual(readiness, .refusedAddress(.cleartextHost("api.example.com")))
        XCTAssertFalse(AssistantAvailability.isUsable(config: config, hasKey: false))
        XCTAssertEqual(
            readiness.message,
            "That address would be reached unencrypted. Use https, "
                + "or 127.0.0.1 for a server on this Mac."
        )
    }

    func testALoopbackAddressIsUsable() {
        var config = AssistantConfiguration.default
        config.isSetUp = true
        config.chat.providerID = "custom"
        config.chat.baseURL = "http://127.0.0.1:8080/v1"
        XCTAssertTrue(AssistantAvailability.isUsable(config: config, hasKey: false))
    }

    func testAServiceThatNeedsAKeyIsNotUsableWithoutOneHoweverGoodTheAddress() {
        var config = AssistantConfiguration.default
        config.isSetUp = true
        config.chat.providerID = "anthropic"
        config.chat.baseURL = "https://api.anthropic.com"
        XCTAssertEqual(
            AssistantAvailability.readiness(config: config, hasKey: false),
            .missingKey(service: "Anthropic")
        )
        XCTAssertEqual(AssistantAvailability.readiness(config: config, hasKey: false).message,
                       "Add a key for Anthropic.")
    }

    /// A key the speech page stored may not turn a record on, even when the
    /// record names a custom endpoint and carries a perfectly good address.
    func testAStoredKeyAloneNeverTurnsACustomEndpointOn() {
        var config = AssistantConfiguration.default
        config.chat.providerID = "custom"
        config.chat.baseURL = "https://proxy.example.com/v1"
        XCTAssertFalse(config.isSetUp)
        XCTAssertEqual(
            AssistantAvailability.readiness(config: config, hasKey: true),
            .notSetUp
        )
        XCTAssertFalse(AssistantAvailability.isUsable(config: config, hasKey: true))
    }

    /// The page and the chips read the same record the request builder reads.
    func testABlankProviderIsReadTheWayTheFactoryReadsIt() {
        var config = AssistantConfiguration.default
        config.isSetUp = true
        config.chat.providerID = "   "
        XCTAssertEqual(
            AssistantAvailability.readiness(config: config, hasKey: false),
            .missingKey(service: "OpenAI"),
            "a blank id falls back to the build's default, as makeProvider does"
        )
        XCTAssertTrue(AssistantAvailability.isUsable(config: config, hasKey: true))
    }

    func testASpaceAroundTheProviderIDFindsTheSameRowAndKey() {
        var local = AssistantConfiguration.default
        local.isSetUp = true
        local.chat.providerID = "  ollama  "
        XCTAssertEqual(
            AssistantAvailability.readiness(config: local, hasKey: false),
            .ready,
            "the trimmed id has to reach Ollama's shipped address"
        )

        var keyed = AssistantConfiguration.default
        keyed.isSetUp = true
        keyed.chat.providerID = "  anthropic  "
        XCTAssertEqual(
            AssistantAvailability.readiness(config: keyed, hasKey: true),
            .ready,
            "the trimmed id has to be the one the key was stored under"
        )
        XCTAssertEqual(
            AssistantAvailability.readiness(config: keyed, hasKey: false),
            .missingKey(service: "Anthropic")
        )
        XCTAssertEqual(
            AssistantProviderCatalogue.model(
                for: AssistantSettings(providerID: "  anthropic  ")
            ),
            "",
            "no row suggests a model, and the trimmed id is the row that is read"
        )
    }

    /// An address can carry a query string or a pasted credential. The status
    /// row gets the reason, never the address itself.
    func testTheStatusLineNeverRepeatsTheAddressItRefused() {
        let secret = "sk-live-0123456789abcdef"
        let rejection = EndpointPolicy.Rejection.notAnAddress(secret)
        let readiness = AssistantAvailability.Readiness.refusedAddress(rejection)
        let message = readiness.message ?? ""
        XCTAssertFalse(message.isEmpty)
        XCTAssertFalse(message.contains(secret), "the typed address reached the status row")
        XCTAssertFalse(AssistantConnectionVerifier.detail(for: rejection).contains(secret))
    }

    func testACheckFailureDoesNotRepeatTheAddressItRefused() {
        var config = AssistantConfiguration.default
        config.isSetUp = true
        config.chat.providerID = "custom"
        config.chat.baseURL = "sk-live-0123456789abcdef"
        let readiness = AssistantAvailability.readiness(config: config, hasKey: false)
        guard case .refusedAddress = readiness else {
            return XCTFail("a value that is not an address was accepted")
        }
        XCTAssertFalse((readiness.message ?? "").contains("sk-live"))
    }

    func testThePageStateFollowsTheRule() {
        let config = AssistantConfiguration.default
        let usable = AssistantAvailability.isUsable(config: config, hasKey: true)
        let state = AssistantConnectionEvent.availability(isUsable: usable).applied(to: .notSetUp)
        XCTAssertEqual(state, .notSetUp)
    }

    // MARK: - Decoding

    func testAConfigurationWithoutTheFlagIsNotSetUp() throws {
        let json = Data(#"{"chat": {"provider": "groq"}}"#.utf8)
        let config = try JSONDecoder().decode(AssistantConfiguration.self, from: json)
        XCTAssertFalse(config.isSetUp)
        XCTAssertEqual(config.chat.providerID, "groq", "the rest of the block survived")
    }

    func testTheFlagRoundTripsAndTheBlockKeepsItsOtherFields() throws {
        var config = AssistantConfiguration.default
        config.isSetUp = true
        config.chat.providerID = "groq"
        let data = try JSONEncoder().encode(config)
        let restored = try JSONDecoder().decode(AssistantConfiguration.self, from: data)
        XCTAssertEqual(restored, config)
        XCTAssertTrue(restored.isSetUp)
    }

    func testAnUnreadableFlagResetsOnlyItself() throws {
        var config = AssistantConfiguration.default
        config.chat.providerID = "groq"
        config.isSetUp = false
        var payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as? [String: Any]
        )
        payload["isSetUp"] = "yes"
        let data = try JSONSerialization.data(withJSONObject: payload)
        let restored = try JSONDecoder().decode(AssistantConfiguration.self, from: data)
        XCTAssertFalse(restored.isSetUp)
        XCTAssertEqual(restored.chat.providerID, "groq")
    }

    // MARK: - The verifier

    private func modelsAnswer() -> StubServer.Response {
        StubServer.Response(status: 200, json: #"{"data":[{"id":"test-model"}]}"#)
    }

    func testTheCheckAsksTheModelsEndpointWithTheKeyInItsHeader() async throws {
        let server = try StubServer(responses: [modelsAnswer()])
        let base = try AssistantTestSupport.loopbackURL(server)
        let result = await AssistantConnectionVerifier.verify(
            settings: settings("openai", baseURL: base.absoluteString),
            apiKey: key,
            session: AssistantTestSupport.session()
        )
        XCTAssertEqual(result, .connected)
        let request = try XCTUnwrap(server.requests.first)
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.path, "/v1/models")
        XCTAssertEqual(request.header("Authorization"), "Bearer \(key)")
        XCTAssertFalse(String(decoding: request.body, as: UTF8.self).contains(key))
    }

    func testALocalServiceIsCheckedWithoutAKey() async throws {
        let server = try StubServer(responses: [modelsAnswer()])
        let base = try AssistantTestSupport.loopbackURL(server)
        let result = await AssistantConnectionVerifier.verify(
            settings: settings("ollama", baseURL: base.absoluteString),
            apiKey: nil,
            session: AssistantTestSupport.session()
        )
        XCTAssertEqual(result, .connected)
        let request = try XCTUnwrap(server.requests.first)
        XCTAssertNil(request.header("Authorization"))
        XCTAssertEqual(request.path, "/v1/models")
    }

    func testAnthropicIsAskedItsOwnWay() async throws {
        let server = try StubServer(responses: [modelsAnswer()])
        let base = try AssistantTestSupport.loopbackURL(server, path: "")
        let result = await AssistantConnectionVerifier.verify(
            settings: settings("anthropic", baseURL: base.absoluteString),
            apiKey: key,
            session: AssistantTestSupport.session()
        )
        XCTAssertEqual(result, .connected)
        let request = try XCTUnwrap(server.requests.first)
        XCTAssertEqual(request.path, "/v1/models")
        XCTAssertEqual(request.header("x-api-key"), key)
        XCTAssertEqual(request.header("anthropic-version"), AnthropicChatProvider.defaultVersion)
        XCTAssertNil(request.header("Authorization"))
    }

    func testARejectedKeyIsNamedAsSuch() async {
        let server = try? StubServer(responses: [
            StubServer.Response(status: 401, json: #"{"error":{"message":"bad key"}}"#),
        ])
        guard let server else { return XCTFail("the stub did not start") }
        guard let base = try? AssistantTestSupport.loopbackURL(server) else {
            return XCTFail("the loopback address was refused")
        }
        let result = await AssistantConnectionVerifier.verify(
            settings: settings("openai", baseURL: base.absoluteString),
            apiKey: key,
            session: AssistantTestSupport.session()
        )
        XCTAssertEqual(result, .notConnected("Rejected the key (401)"))
        XCTAssertEqual(result.state.detail, "Rejected the key (401)")
    }

    /// A failed answer is a status, never its body.
    ///
    /// A proxy can repeat the credential it was sent in the error body. The
    /// status row names the refusal and nothing from the document.
    func testARejectedAnswerNeverShowsItsBody() async {
        let secret = "sk-live-0123456789abcdef"
        let server = try? StubServer(responses: [
            StubServer.Response(
                status: 401,
                json: #"{"error":"bad key \#(secret)","hint":"Authorization: Bearer \#(secret)"}"#
            ),
        ])
        guard let server else { return XCTFail("the stub did not start") }
        guard let base = try? AssistantTestSupport.loopbackURL(server) else {
            return XCTFail("the loopback address was refused")
        }
        let result = await AssistantConnectionVerifier.verify(
            settings: settings("openai", baseURL: base.absoluteString),
            apiKey: secret,
            session: AssistantTestSupport.session()
        )
        XCTAssertEqual(result, .notConnected("Rejected the key (401)"))
        let detail = result.state.detail ?? ""
        XCTAssertFalse(detail.contains(secret), "the response body reached the status row")
        XCTAssertFalse(detail.contains("hint"))
    }

    func testAnUnreachableServiceSaysSo() async throws {
        let port = try ClosedPort.make()
        let result = await AssistantConnectionVerifier.verify(
            settings: settings("openai", baseURL: "http://127.0.0.1:\(port)/v1"),
            apiKey: key,
            session: AssistantTestSupport.session()
        )
        guard case .notConnected(let reason) = result else {
            return XCTFail("expected a failure, got \(result)")
        }
        XCTAssertFalse(reason.isEmpty)
        XCTAssertFalse(reason.contains(key), "the key reached the status row")
    }

    func testTheStatusSentences() {
        XCTAssertEqual(AssistantConnectionVerifier.detail(forStatus: 401), "Rejected the key (401)")
        XCTAssertEqual(AssistantConnectionVerifier.detail(forStatus: 403), "Rejected the key (403)")
        XCTAssertEqual(AssistantConnectionVerifier.detail(forStatus: 500), "The service answered 500")
        XCTAssertEqual(AssistantConnectionVerifier.detail(forStatus: 429), "The service answered 429")
    }

    func testACheckGivesUpAfterEightSeconds() {
        XCTAssertEqual(AssistantConnectionVerifier.timeout, 8)
    }

    // MARK: - The cache

    func testAFreshAnswerIsReusedAndAnOldOneIsNot() async {
        let cache = AssistantConnectionCache()
        let service = AssistantConnectionCache.serviceKey(settings("openai"))
        let at = Date(timeIntervalSince1970: 1_000_000)
        await cache.store(.connected, for: service, at: at)

        let fresh = await cache.result(for: service, now: at.addingTimeInterval(60))
        XCTAssertEqual(fresh, .connected)
        let stale = await cache.result(
            for: service,
            now: at.addingTimeInterval(AssistantConnectionCache.lifetime)
        )
        XCTAssertNil(stale)
        XCTAssertEqual(AssistantConnectionCache.lifetime, 600)
    }

    func testTheAddressIsPartOfWhatWasChecked() {
        let first = AssistantConnectionCache.serviceKey(settings("xiaomi"))
        let second = AssistantConnectionCache.serviceKey(
            settings("xiaomi", baseURL: "https://token-plan-cn.xiaomimimo.com/v1")
        )
        XCTAssertNotEqual(first, second, "a service the person moved is checked again")
    }
}
