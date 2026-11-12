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

        // A hand-filled endpoint is the same case: the row requires no key.
        config.chat.providerID = "my-proxy"
        XCTAssertTrue(AssistantAvailability.isUsable(config: config, hasKey: false))
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

    func testAnUnreachableServiceSaysSo() async {
        // Nothing listens on port 9 of this Mac: the transport fails at once,
        // and the line is the sanitised reason rather than an empty green dot.
        let result = await AssistantConnectionVerifier.verify(
            settings: settings("openai", baseURL: "http://127.0.0.1:9/v1"),
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
