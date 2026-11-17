import XCTest

@testable import DotCore

/// The live model list: what each service publishes, and how much of it Dot
/// believes.
///
/// Every payload here is synthetic and every server is a loopback stub. No key
/// in this file belongs to an account, and nothing leaves this Mac: a pass says
/// the parser reads the shapes the catalogue's services document, not that a
/// particular service answers one today.
final class AssistantModelCatalogTests: XCTestCase {
    private func models(_ json: String, excluding prefixes: [String] = []) -> [DiscoveredModel] {
        AssistantModelCatalog.catalogModels(in: Data(json.utf8), excluding: prefixes)
    }

    // MARK: - Entries that are not a chat model

    func testEveryKindOfNonChatEntryIsDropped() {
        let listed = models(
            """
            {"data":[
              {"id":"whisper-1"},
              {"id":"tts-1"},
              {"id":"dall-e-3"},
              {"id":"text-embedding-3-small"},
              {"id":"embedding-2"},
              {"id":"omni-moderation-latest"},
              {"id":"sora-2"},
              {"id":"gpt-image-1"},
              {"id":"babbage-002"},
              {"id":"davinci-002"},
              {"id":"mistral-embed"},
              {"id":"voxtral-mini"},
              {"id":"gpt-4o"},
              {"id":"embed-model","type":"embedding"},
              {"id":"image-model","type":"image"},
              {"id":"ocr-model","type":"ocr"},
              {"id":"chat-model","type":"chat"},
              {"id":"claude-opus-5","type":"model"},
              {"id":"mistral-small","capabilities":{"completion_chat":false}},
              {"id":"mistral-large","capabilities":{"completion_chat":true}}
            ]}
            """
        )
        XCTAssertEqual(
            listed.map(\.id),
            ["gpt-4o", "chat-model", "claude-opus-5", "mistral-large"],
            "a chat picker may only offer chat models, in the order the service wrote them"
        )
        XCTAssertEqual(
            AssistantModelCatalog.models(
                in: Data(#"{"data":[{"id":"grok-4"},{"id":"grok-5"}]}"#.utf8),
                excluding: ["grok-"]
            ),
            [],
            "a row's exclusions still apply"
        )
    }

    func testAChatEntryIsReadFromEveryFieldAServicePublishes() {
        let listed = models(
            """
            {"data":[{
              "id":"claude-sonnet-5",
              "name":"Claude Sonnet 5",
              "type":"chat",
              "capabilities":{"temperature":false}
            }]}
            """
        )
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed.first?.id, "claude-sonnet-5")
        XCTAssertEqual(listed.first?.name, "Claude Sonnet 5")
        XCTAssertEqual(listed.first?.supportsTemperature, false)
        XCTAssertNil(listed.first?.reasoning)
        XCTAssertNil(listed.first?.route)
    }

    func testAnAnonymousEntryFallsBackToTheIdAsItsName() {
        let listed = models(#"{"data":[{"id":"glm-5.3"}]}"#)
        XCTAssertEqual(listed.first?.name, nil, "nothing was published, so nothing is invented")
    }

    func testAListNobodyCanReadNamesNothing() {
        XCTAssertEqual(models("not json"), [])
        XCTAssertEqual(models(#"{"object":"list"}"#), [])
        XCTAssertEqual(models(#"{"data":[]}"#), [])
        XCTAssertEqual(models(#"{"data":[{"id":"   "},{}]}"#), [])
    }

    // MARK: - The route a model is served at

    func testTheOpenCodeGoRoutesAreReadFromTheAPIMember() {
        let listed = models(
            """
            {"object":"list","data":[
              {"id":"claude-haiku-5-5",
               "api":{"messages":{"base_url":"https://opencode.ai/inference/go/anthropic/v1"}}},
              {"id":"glm-5.3",
               "api":{"chat-completions":{"base_url":"https://opencode.ai/inference/go/openai/v1"}}},
              {"id":"muse-spark-1",
               "api":{"responses":{"base_url":"https://opencode.ai/inference/go/openai/v1"}}},
              {"id":"gemini-4-argon",
               "api":{"generate-content":{"base_url":"https://opencode.ai/inference/go/google/v1beta"}}}
            ]}
            """
        )
        XCTAssertEqual(
            listed.map(\.id),
            ["claude-haiku-5-5", "glm-5.3"],
            "a model served only on a shape this build cannot speak is never offered"
        )
        XCTAssertEqual(listed.first?.route?.style, .anthropic)
        XCTAssertEqual(
            listed.first?.route?.baseURL.absoluteString,
            "https://opencode.ai/inference/go/anthropic/v1"
        )
        XCTAssertEqual(listed.last?.route?.style, .openAICompatible)
        XCTAssertEqual(
            listed.last?.route?.baseURL.absoluteString,
            "https://opencode.ai/inference/go/openai/v1"
        )
    }

    func testARouteArrivesHoweverTheServiceSpellsIt() {
        let asAString = models(
            #"{"data":[{"id":"m","api":"messages","base_url":"https://example.com/anthropic/v1"}]}"#
        )
        XCTAssertEqual(asAString.first?.route?.style, .anthropic)
        XCTAssertEqual(
            asAString.first?.route?.baseURL.absoluteString,
            "https://example.com/anthropic/v1",
            "a model-level address is used when the shape carries none"
        )

        let asAnArray = models(
            #"{"data":[{"id":"m","api":["chat-completions"],"base_url":"https://example.com/v1"}]}"#
        )
        XCTAssertEqual(asAnArray.first?.route?.style, .openAICompatible)

        let withoutAddress = models(#"{"data":[{"id":"m","api":{"messages":{}}}]}"#)
        XCTAssertEqual(withoutAddress.count, 1, "the model is still offered")
        XCTAssertNil(withoutAddress.first?.route, "a route this build cannot build is not one")
    }

    func testAModelWithNoAPIMemberKeepsTheRowsOwnShape() {
        let listed = models(#"{"data":[{"id":"glm-5.3"}]}"#)
        XCTAssertNil(listed.first?.route, "the row's shape is right when the service says nothing")
    }

    // MARK: - Reasoning

    func testOpenCodeGoReasoningComesFromItsCapabilities() {
        let listed = models(
            """
            {"data":[{
              "id":"kimi-k3",
              "capabilities":{
                "reasoning":{
                  "supported":true,
                  "toggle":true,
                  "effort":["low","high","max"],
                  "default":{"value":"high"}
                }
              }
            }]}
            """
        )
        let reasoning = listed.first?.reasoning
        XCTAssertEqual(reasoning?.efforts, ["low", "high", "max"])
        XCTAssertEqual(reasoning?.toggle, true)
        XCTAssertEqual(reasoning?.defaultEffort, "high")
        XCTAssertEqual(reasoning?.supportsReasoning, true)
    }

    func testAnthropicReasoningComesFromItsThinkingTypesAndEffortFlags() {
        let listed = models(
            """
            {"data":[{
              "id":"claude-sonnet-5",
              "capabilities":{
                "thinking":{"types":["enabled","adaptive","disabled"]},
                "effort":{"low":true,"medium":true,"high":true,"xhigh":true,"max":false}
              }
            }]}
            """
        )
        let reasoning = listed.first?.reasoning
        XCTAssertEqual(reasoning?.toggle, true, "enabled and adaptive thinking can be turned on")
        XCTAssertEqual(reasoning?.efforts, ["low", "medium", "high", "xhigh"])
        XCTAssertEqual(reasoning?.thinkingTypes, ["enabled", "adaptive", "disabled"])
    }

    func testDeepSeekReasoningComesFromItsEffortLevels() {
        let listed = models(
            """
            {"data":[{
              "id":"deepseek-reasoner",
              "effort":{"supported_levels":["low","high"],"default_level":"high"}
            }]}
            """
        )
        XCTAssertEqual(listed.first?.reasoning?.efforts, ["low", "high"])
        XCTAssertEqual(listed.first?.reasoning?.defaultEffort, "high")
        XCTAssertEqual(listed.first?.reasoning?.toggle, false)
    }

    func testXAIReasoningComesFromItsReasoningEffortCapability() {
        let listed = models(
            """
            {"data":[{
              "id":"grok-4",
              "capabilities":{
                "reasoning_effort":["low","high"],
                "default_reasoning_effort":"low"
              }
            }]}
            """
        )
        XCTAssertEqual(listed.first?.reasoning?.efforts, ["low", "high"])
        XCTAssertEqual(listed.first?.reasoning?.defaultEffort, "low")
    }

    func testOpenRouterReasoningComesFromItsSupportedParameters() {
        let listed = models(
            """
            {"data":[{
              "id":"openai/gpt-6",
              "supported_parameters":["tools","reasoning"],
              "reasoning":{"supported_efforts":["low","high","xhigh"],"default_effort":"low","default_enabled":true}
            }]}
            """
        )
        let reasoning = listed.first?.reasoning
        XCTAssertEqual(reasoning?.efforts, ["low", "high", "xhigh"])
        XCTAssertEqual(reasoning?.toggle, true)
        XCTAssertEqual(reasoning?.defaultEffort, "low")
    }

    func testNoEffortIsInventedWhenTheServicePublishedNone() {
        let listed = models(
            """
            {"data":[
              {"id":"gpt-5-mini","capabilities":{"reasoning":{"supported":true}}},
              {"id":"deepseek-chat"},
              {"id":"claude-test","capabilities":{"thinking":{"types":["disabled"]}}},
              {"id":"openrouter-model","supported_parameters":["tools","temperature"]}
            ]}
            """
        )
        for model in listed {
            XCTAssertNil(
                model.reasoning,
                "\(model.id) published no level, and a level Dot invented would be refused"
            )
        }
    }

    func testAnEffortMapWrittenAsFlagsIsStillRead() {
        let listed = models(
            """
            {"data":[{
              "id":"m",
              "capabilities":{"reasoning":{"toggle":true,"effort":{"low":true,"medium":false,"high":true}}}
            }]}
            """
        )
        XCTAssertEqual(listed.first?.reasoning?.efforts, ["low", "high"])
    }

    // MARK: - Fetching

    private func anthropicSettings(_ server: StubServer) throws -> AssistantSettings {
        AssistantSettings(
            providerID: "anthropic",
            model: "claude-test",
            baseURL: try AssistantTestSupport.loopbackURL(server, path: "").absoluteString
        )
    }

    func testAFetchReadsTheCatalogueWithWhatWasPublished() async throws {
        let server = try StubServer(responses: [
            StubServer.Response(
                status: 200,
                json: """
                {"data":[
                  {"id":"claude-haiku-5-5",
                   "api":{"messages":{"base_url":"https://opencode.ai/inference/go/anthropic/v1"}},
                   "capabilities":{"reasoning":{"toggle":true,"effort":["low","high"]}}}
                ],"has_more":false,"last_id":"claude-haiku-5-5"}
                """
            ),
        ])
        let result = await AssistantModelCatalog.fetchCatalog(
            settings: try anthropicSettings(server),
            apiKey: "sk-test",
            session: AssistantTestSupport.session(),
            cache: AssistantModelCache()
        )
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.models.map(\.id), ["claude-haiku-5-5"])
        XCTAssertEqual(result.models.first?.route?.style, .anthropic)
        XCTAssertEqual(result.models.first?.reasoning?.efforts, ["low", "high"])
        XCTAssertEqual(
            server.requests.first?.path,
            "/v1/models",
            "the list is read at the Anthropic models path"
        )
        XCTAssertTrue(
            server.requests.first?.query.contains("limit=1000") == true,
            "an account may hold more models than one answer carries"
        )
    }

    /// A typed address that already ends in the version segment is not asked
    /// for it twice.
    ///
    /// Anthropic's own base URL has no `v1`, so the models path supplies it. A
    /// person who stores `https://api.anthropic.com/v1` — the form the vendor's
    /// documentation shows for messages — must reach `/v1/models`, not
    /// `/v1/v1/models`.
    func testAnAddressThatAlreadyEndsInV1IsNotDoubled() async throws {
        let server = try StubServer(responses: [
            StubServer.Response(
                status: 200,
                json: #"{"data":[{"id":"claude-a"}],"has_more":false}"#
            ),
        ])
        var settings = AssistantSettings(providerID: "anthropic", model: "claude-test")
        settings.baseURL = try AssistantTestSupport.loopbackURL(server, path: "/v1").absoluteString
        let result = await AssistantModelCatalog.fetchCatalog(
            settings: settings,
            apiKey: "sk-test",
            session: AssistantTestSupport.session(),
            cache: AssistantModelCache()
        )
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(
            server.requests.first?.path,
            "/v1/models",
            "the version segment was appended to a base URL that already had one"
        )
    }

    func testAFetchFollowsAnthropicsPages() async throws {
        let server = try StubServer(responses: [
            StubServer.Response(
                status: 200,
                json: #"{"data":[{"id":"claude-a"}],"has_more":true,"last_id":"claude-a"}"#
            ),
            StubServer.Response(
                status: 200,
                json: #"{"data":[{"id":"claude-b"}],"has_more":false,"last_id":"claude-b"}"#
            ),
        ])
        let result = await AssistantModelCatalog.fetchCatalog(
            settings: try anthropicSettings(server),
            apiKey: "sk-test",
            session: AssistantTestSupport.session(),
            cache: AssistantModelCache()
        )
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.models.map(\.id), ["claude-a", "claude-b"])
        XCTAssertEqual(server.requests.count, 2)
        XCTAssertTrue(server.requests[0].query.contains("limit=1000"))
        XCTAssertFalse(server.requests[0].query.contains("after_id"))
        XCTAssertTrue(server.requests[1].query.contains("after_id=claude-a"))
    }

    func testAFetchStopsAfterFivePages() async throws {
        let page = StubServer.Response(
            status: 200,
            json: #"{"data":[{"id":"claude-a"}],"has_more":true,"last_id":"claude-a"}"#
        )
        let server = try StubServer(responses: Array(repeating: page, count: 8))
        let result = await AssistantModelCatalog.fetchCatalog(
            settings: try anthropicSettings(server),
            apiKey: "sk-test",
            session: AssistantTestSupport.session(),
            cache: AssistantModelCache()
        )
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(server.requests.count, 5, "a list that never ends must not hold the page")
    }

    /// A page that stops part way is not the whole catalogue, and it is not
    /// cached as if it were.
    ///
    /// The first page is a real answer, so the picker may show it; the second
    /// page failing means the list is incomplete, and the next visit must ask
    /// again rather than reuse half an account's models for ten minutes.
    func testAPartialPageIsReportedIncompleteAndNotCached() async throws {
        let cache = AssistantModelCache()
        let server = try StubServer(responses: [
            StubServer.Response(
                status: 200,
                json: #"{"data":[{"id":"claude-a"}],"has_more":true,"last_id":"claude-a"}"#
            ),
            StubServer.Response(status: 500, json: #"{"error":{"message":"broken"}}"#),
            StubServer.Response(
                status: 200,
                json: #"{"data":[{"id":"claude-a"}],"has_more":false}"#
            ),
        ])
        let settings = try anthropicSettings(server)
        let session = AssistantTestSupport.session()
        let partial = await AssistantModelCatalog.fetchCatalog(
            settings: settings,
            apiKey: "sk-test",
            session: session,
            cache: cache
        )
        XCTAssertTrue(partial.succeeded)
        XCTAssertFalse(partial.complete, "a page that failed was reported as complete")
        XCTAssertEqual(partial.models.map(\.id), ["claude-a"])

        let second = await AssistantModelCatalog.fetchCatalog(
            settings: settings,
            apiKey: "sk-test",
            session: session,
            cache: cache
        )
        XCTAssertTrue(second.complete)
        XCTAssertEqual(
            server.requests.count,
            3,
            "a partial list was reused from the cache instead of being read again"
        )
    }

    /// A list that never ends is incomplete even though every page answered.
    func testAListThatHitsThePageCeilingIsIncomplete() async throws {
        let cache = AssistantModelCache()
        let page = StubServer.Response(
            status: 200,
            json: #"{"data":[{"id":"claude-a"}],"has_more":true,"last_id":"claude-a"}"#
        )
        let server = try StubServer(responses: Array(repeating: page, count: 10))
        let settings = try anthropicSettings(server)
        let result = await AssistantModelCatalog.fetchCatalog(
            settings: settings,
            apiKey: "sk-test",
            session: AssistantTestSupport.session(),
            cache: cache
        )
        XCTAssertTrue(result.succeeded)
        XCTAssertFalse(result.complete, "the page ceiling was reported as the whole list")

        _ = await AssistantModelCatalog.fetchCatalog(
            settings: settings,
            apiKey: "sk-test",
            session: AssistantTestSupport.session(),
            cache: cache
        )
        XCTAssertEqual(server.requests.count, 10, "an unfinished list was cached")
    }

    func testAFreshCatalogueIsReusedAndAFailedOneIsNotStored() async throws {
        let cache = AssistantModelCache()
        let server = try StubServer(responses: [
            StubServer.Response(status: 500, json: #"{"error":{"message":"broken"}}"#),
            StubServer.Response(status: 200, json: #"{"data":[{"id":"claude-a"}],"has_more":false}"#),
            StubServer.Response(status: 200, json: #"{"data":[{"id":"claude-a"}],"has_more":false}"#),
        ])
        let settings = try anthropicSettings(server)
        let session = AssistantTestSupport.session()

        let failed = await AssistantModelCatalog.fetchCatalog(
            settings: settings,
            apiKey: "sk-test",
            session: session,
            cache: cache
        )
        XCTAssertFalse(failed.succeeded, "a refusal is told apart from an empty list")
        XCTAssertEqual(failed.models, [])

        let read = await AssistantModelCatalog.fetchCatalog(
            settings: settings,
            apiKey: "sk-test",
            session: session,
            cache: cache
        )
        XCTAssertTrue(read.succeeded)
        XCTAssertEqual(read.models.map(\.id), ["claude-a"])

        let reused = await AssistantModelCatalog.fetchCatalog(
            settings: settings,
            apiKey: "sk-test",
            session: session,
            cache: cache
        )
        XCTAssertEqual(reused.models.map(\.id), ["claude-a"])
        XCTAssertEqual(
            server.requests.count,
            2,
            "a refusal is not cached, and a fresh answer is not read twice"
        )
    }

    func testAnOldCatalogueIsNotReused() async {
        let cache = AssistantModelCache()
        let service = AssistantModelCache.serviceKey(AssistantSettings(providerID: "openai"), hasKey: true)
        let at = Date(timeIntervalSince1970: 1_000_000)
        await cache.store([DiscoveredModel(id: "gpt-4o")], for: service, at: at)
        let fresh = await cache.models(for: service, now: at.addingTimeInterval(60))
        XCTAssertEqual(fresh?.map(\.id), ["gpt-4o"])
        let stale = await cache.models(
            for: service,
            now: at.addingTimeInterval(AssistantModelCache.lifetime)
        )
        XCTAssertNil(stale)
        XCTAssertEqual(AssistantModelCache.lifetime, 600)
    }

    func testTheAddressTheStyleAndTheKeyArePartOfWhatWasRead() {
        let base = AssistantSettings(providerID: "openai")
        XCTAssertNotEqual(
            AssistantModelCache.serviceKey(base, hasKey: true, credential: "sk-a"),
            AssistantModelCache.serviceKey(base, hasKey: false),
            "a key added later has to be read again"
        )
        var moved = base
        moved.baseURL = "https://proxy.example.com/v1"
        XCTAssertNotEqual(
            AssistantModelCache.serviceKey(base, hasKey: true, credential: "sk-a"),
            AssistantModelCache.serviceKey(moved, hasKey: true, credential: "sk-a"),
            "a service the person moved is read at its new address"
        )
        var shaped = base
        shaped.apiStyle = .anthropic
        XCTAssertNotEqual(
            AssistantModelCache.serviceKey(base, hasKey: true, credential: "sk-a"),
            AssistantModelCache.serviceKey(shaped, hasKey: true, credential: "sk-a"),
            "a shape override asks a different endpoint for a different list"
        )
        XCTAssertNotEqual(
            AssistantModelCache.serviceKey(base, hasKey: true, credential: "sk-a"),
            AssistantModelCache.serviceKey(base, hasKey: true, credential: "sk-b"),
            "a replaced key belongs to another account and another list"
        )
        XCTAssertFalse(
            AssistantModelCache.serviceKey(base, hasKey: true, credential: "sk-a").contains("sk-a"),
            "the credential was written into the cache key"
        )
    }

    func testAnUnreadableAnswerIsNotSuccess() async throws {
        let server = try StubServer(responses: [
            StubServer.Response(status: 200, body: Data("not json".utf8)),
        ])
        let result = await AssistantModelCatalog.fetchCatalog(
            settings: try anthropicSettings(server),
            apiKey: "sk-test",
            session: AssistantTestSupport.session(),
            cache: AssistantModelCache()
        )
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.models, [])
    }

    func testAListWithNoAddressIsNotAsked() async {
        let result = await AssistantModelCatalog.fetchCatalog(
            settings: AssistantSettings(providerID: "custom", model: "m"),
            apiKey: nil,
            session: AssistantTestSupport.session(),
            cache: AssistantModelCache()
        )
        XCTAssertFalse(result.succeeded)
    }
}
