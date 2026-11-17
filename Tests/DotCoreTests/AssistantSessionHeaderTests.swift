import XCTest

@testable import DotCore

/// OpenCode Go's session header: which requests carry it, what it looks like,
/// how long it lives, and where it must never go.
///
/// Every test here is offscreen and synthetic. The key is a string this file
/// invented, the endpoint is a loopback ``StubServer``, and nothing leaves this
/// Mac: a pass proves the request Dot builds, not that a particular
/// subscription or key works. A real key is never read and the service is never
/// contacted.
final class AssistantSessionHeaderTests: XCTestCase {
    /// A key that belongs to no account.
    private let syntheticKey = "sk-synthetic-0123456789abcdef"
    private let headerName = AssistantSessionHeader.openCodeGo.rawValue

    // MARK: - Helpers

    private func goProvider(
        _ server: StubServer,
        apiKey: String? = nil,
        sessionHeader: AssistantSessionHeader? = .openCodeGo
    ) throws -> OpenAIChatProvider {
        OpenAIChatProvider(
            baseURL: try AssistantTestSupport.loopbackURL(server),
            apiKey: apiKey ?? syntheticKey,
            sessionHeader: sessionHeader,
            session: AssistantTestSupport.session()
        )
    }

    private func sseResponse() -> StubServer.Response {
        StubServer.Response(
            status: 200,
            body: AssistantTestSupport.sse([
                #"{"choices":[{"delta":{"content":"ok"},"finish_reason":"stop"}]}"#,
                "[DONE]",
            ]),
            contentType: "text/event-stream"
        )
    }

    /// The session id a request carries, read the way the service reads it.
    private func sessionID(in request: URLRequest) -> String? {
        request.value(forHTTPHeaderField: headerName)
    }

    /// Asserts an id has Go's shape: `ses_` and a lowercase UUID.
    private func assertLooksLikeASessionID(
        _ id: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(id.hasPrefix("ses_"), "\(id) does not start with ses_", file: file, line: line)
        let suffix = String(id.dropFirst("ses_".count))
        XCTAssertEqual(suffix.count, 36, "\(id) is not a UUID after its prefix", file: file, line: line)
        XCTAssertEqual(suffix, suffix.lowercased(), "\(id) is not written in lowercase", file: file, line: line)
        XCTAssertNotNil(
            UUID(uuidString: suffix),
            "\(id) does not carry a UUID after its prefix",
            file: file,
            line: line
        )
    }

    // MARK: - What the request carries

    func testAGoProviderSendsOneSessionIDOnEveryRequestItMakes() async throws {
        let server = try StubServer(responses: [sseResponse(), sseResponse()])
        let provider = try goProvider(server)

        // Two turns of one conversation, streamed the way the session sends
        // them, and the request builder itself, which is the seam a caller that
        // does not stream would use.
        _ = try await AssistantTestSupport.events(
            provider.stream(messages: [.user("hi")], tools: [], model: "m")
        )
        _ = try await AssistantTestSupport.events(
            provider.stream(messages: [.user("again")], tools: [], model: "m")
        )
        let built = try provider.makeRequest(messages: [.user("built")], tools: [], model: "m")

        let first = try XCTUnwrap(server.requests.first)
        let second = try XCTUnwrap(server.requests.last)
        XCTAssertEqual(server.requests.count, 2)
        let sent = try XCTUnwrap(first.header(headerName), "the first request carried no session id")
        let sentAgain = try XCTUnwrap(second.header(headerName), "the second request carried no session id")
        let builtID = try XCTUnwrap(sessionID(in: built), "the built request carried no session id")

        XCTAssertEqual(sent, sentAgain, "one provider is one conversation, so every request names it the same")
        XCTAssertEqual(sent, builtID, "the stream and the built request are the same request")
        XCTAssertEqual(sent, provider.sessionID)
        assertLooksLikeASessionID(sent)
        XCTAssertEqual(
            first.path,
            "/v1/chat/completions",
            "the id travels on the documented Go inference path"
        )
    }

    func testTheSessionIDHasTheShapeGoWritesOne() throws {
        let server = try StubServer(responses: [])
        let id = try XCTUnwrap(try goProvider(server).sessionID)
        assertLooksLikeASessionID(id)
        XCTAssertEqual(id.count, 40, "ses_ plus a hyphenated lowercase UUID")
    }

    func testIndependentlyBuiltGoProvidersNameDifferentConversations() async throws {
        let server = try StubServer(responses: [sseResponse(), sseResponse()])
        let first = try goProvider(server)
        let second = try goProvider(server)

        let firstID = try XCTUnwrap(first.sessionID)
        let secondID = try XCTUnwrap(second.sessionID)
        XCTAssertNotEqual(firstID, secondID, "a new provider is a new conversation")

        _ = try await AssistantTestSupport.events(
            first.stream(messages: [.user("hi")], tools: [], model: "m")
        )
        _ = try await AssistantTestSupport.events(
            second.stream(messages: [.user("hi")], tools: [], model: "m")
        )
        let sent = try XCTUnwrap(server.requests.first?.header(headerName))
        let sentAgain = try XCTUnwrap(server.requests.last?.header(headerName))
        XCTAssertEqual(sent, firstID)
        XCTAssertEqual(sentAgain, secondID)
        XCTAssertNotEqual(sent, sentAgain)
    }

    func testTheSessionHeaderLeavesTheAuthorizationAndTheBodyAlone() throws {
        let server = try StubServer(responses: [])
        let provider = try goProvider(server)
        let request = try provider.makeRequest(messages: [.user("hi")], tools: [], model: "test-model")
        let id = try XCTUnwrap(provider.sessionID)

        XCTAssertEqual(request.value(forHTTPHeaderField: headerName), id)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(syntheticKey)")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "text/event-stream")

        let body = AssistantTestSupport.json(request.httpBody)
        XCTAssertEqual(body["model"] as? String, "test-model")
        XCTAssertEqual(body["stream"] as? Bool, true)

        // The id names a conversation on the service; it belongs in no body
        // member, no address and no other header.
        XCTAssertFalse(String(decoding: request.httpBody ?? Data(), as: UTF8.self).contains(id))
        XCTAssertFalse(request.url?.absoluteString.contains(id) ?? true)
        XCTAssertEqual(request.allHTTPHeaderFields?.values.filter { $0 == id }.count, 1)
        XCTAssertEqual(
            Set((request.allHTTPHeaderFields ?? [:]).keys.map { $0.lowercased() }),
            ["content-type", "accept", "authorization", headerName],
            "the request carries the key, the stream's headers and the session, and nothing else"
        )

        // A Go provider with no key at all still names its conversation: the
        // header is the client's, not a function of the credential.
        let keyless = try goProvider(server, apiKey: "")
        let keylessRequest = try keyless.makeRequest(messages: [.user("hi")], tools: [], model: "m")
        XCTAssertNotNil(sessionID(in: keylessRequest))
        XCTAssertNil(keylessRequest.value(forHTTPHeaderField: "Authorization"))
    }

    func testARejectedKeyStillCarriesTheSessionHeader() async throws {
        let server = try StubServer(responses: [
            StubServer.Response(status: 401, json: #"{"error":{"message":"invalid key"}}"#)
        ])
        do {
            _ = try await AssistantTestSupport.events(
                try goProvider(server).stream(messages: [.user("hi")], tools: [], model: "m")
            )
            XCTFail("a refused key must fail the read")
        } catch let error as ProviderError {
            XCTAssertEqual(error, .rejected(status: 401, message: "invalid key"))
        }
        let sent = try XCTUnwrap(
            server.requests.first?.header(headerName),
            "the refusal is the key's, not a missing session: the header went out"
        )
        assertLooksLikeASessionID(sent)
    }

    // MARK: - Where the header must never go

    func testAProviderWithoutASessionHeaderSendsNone() async throws {
        let server = try StubServer(responses: [sseResponse()])
        let provider = try goProvider(server, sessionHeader: nil)
        XCTAssertNil(provider.sessionHeader)
        XCTAssertNil(provider.sessionID)

        _ = try await AssistantTestSupport.events(
            provider.stream(messages: [.user("hi")], tools: [], model: "m")
        )
        XCTAssertNil(server.requests.first?.header(headerName))
        let built = try provider.makeRequest(messages: [.user("hi")], tools: [], model: "m")
        XCTAssertEqual(
            Set(built.allHTTPHeaderFields?.keys.map { $0.lowercased() } ?? []),
            ["content-type", "accept", "authorization"],
            "an endpoint that asked for no session header is sent none"
        )
    }

    func testOnlyTheGoRowNamesASessionHeader() {
        for row in AssistantProviderCatalogue.rows {
            if row.id == AssistantProviderID.openCodeGo {
                XCTAssertEqual(row.sessionHeader, .openCodeGo)
            } else {
                XCTAssertNil(row.sessionHeader, "\(row.id) never asked for a session header")
            }
        }
        XCTAssertNil(
            AssistantProviderCatalogue.row(for: "my-proxy").sessionHeader,
            "an endpoint the catalogue does not know is sent none"
        )
        XCTAssertFalse(
            AssistantProviderCatalogue.row(for: AssistantProviderID.openCodeGo)
                .extraHeaders.keys.contains { $0.lowercased() == headerName },
            "the id is minted per provider, never shipped as a static header"
        )
    }

    func testEveryOtherVendorBuildsAProviderThatSendsNoSessionHeader() throws {
        for row in AssistantProviderCatalogue.rows
        where row.id != AssistantProviderCatalogue.customRow.id
            && row.id != AssistantProviderID.openCodeGo {
            let settings = AssistantSettings(providerID: row.id)
            let provider = try AssistantProviderCatalogue.makeProvider(
                settings: settings,
                apiKey: syntheticKey,
                session: AssistantTestSupport.session()
            )
            if let openAI = provider as? OpenAIChatProvider {
                XCTAssertNil(openAI.sessionHeader, "\(row.id) does not name a session header")
                XCTAssertNil(openAI.sessionID, "\(row.id) is sent no session id")
                let request = try openAI.makeRequest(messages: [.user("hi")], tools: [], model: "m")
                XCTAssertNil(sessionID(in: request), "\(row.id) received a Go-only header")
            } else {
                XCTAssertEqual(row.style, .anthropic, "\(row.id) builds a provider this test does not know")
            }
        }
    }

    func testACustomEndpointIsNeverSentTheHeaderEvenAtTheVendorsOwnAddress() throws {
        var settings = AssistantSettings(providerID: AssistantProviderCatalogue.customRow.id)
        settings.baseURL = "https://opencode.ai/inference/go/openai/v1"
        let provider = try XCTUnwrap(
            try AssistantProviderCatalogue.makeProvider(settings: settings, apiKey: nil) as? OpenAIChatProvider
        )
        XCTAssertNil(provider.sessionHeader, "the address does not make an endpoint the Go row")
        XCTAssertNil(provider.sessionID)
        let request = try provider.makeRequest(messages: [.user("hi")], tools: [], model: "m")
        XCTAssertNil(sessionID(in: request))

        var unknown = AssistantSettings(providerID: "my-proxy")
        unknown.baseURL = "https://proxy.example.com/v1"
        let proxied = try XCTUnwrap(
            try AssistantProviderCatalogue.makeProvider(settings: unknown, apiKey: syntheticKey) as? OpenAIChatProvider
        )
        XCTAssertNil(proxied.sessionID)
        XCTAssertNil(sessionID(in: try proxied.makeRequest(messages: [.user("hi")], tools: [], model: "m")))

        // Another vendor's row with a typed address keeps its own identity: the
        // header belongs to the Go row, not to a host name.
        var elsewhere = AssistantSettings(
            providerID: "openai",
            baseURL: "https://opencode.ai/inference/go/openai/v1"
        )
        elsewhere.model = "gpt-4o-mini"
        let other = try XCTUnwrap(
            try AssistantProviderCatalogue.makeProvider(settings: elsewhere, apiKey: syntheticKey) as? OpenAIChatProvider
        )
        XCTAssertNil(other.sessionHeader, "the address does not make another vendor's row the Go row")
        XCTAssertNil(other.sessionID)
        XCTAssertNil(sessionID(in: try other.makeRequest(messages: [.user("hi")], tools: [], model: "m")))
    }

    // MARK: - The factory paths

    func testTheGoRowBuildsAProviderWhoseRequestsNameTheConversation() async throws {
        let server = try StubServer(responses: [sseResponse(), sseResponse()])
        let settings = AssistantSettings(
            providerID: AssistantProviderID.openCodeGo,
            baseURL: try AssistantTestSupport.loopbackURL(server).absoluteString
        )
        let provider = try XCTUnwrap(
            try AssistantProviderCatalogue.makeProvider(
                settings: settings,
                apiKey: syntheticKey,
                session: AssistantTestSupport.session()
            ) as? OpenAIChatProvider
        )
        let id = try XCTUnwrap(provider.sessionID)
        assertLooksLikeASessionID(id)

        _ = try await AssistantTestSupport.events(
            provider.stream(messages: [.user("hi")], tools: [], model: "m")
        )
        _ = try await AssistantTestSupport.events(
            provider.stream(messages: [.user("hi again")], tools: [], model: "m")
        )
        XCTAssertEqual(server.requests.first?.header(headerName), id)
        XCTAssertEqual(server.requests.last?.header(headerName), id)

        let again = try XCTUnwrap(
            try AssistantProviderCatalogue.makeProvider(
                settings: settings,
                apiKey: syntheticKey,
                session: AssistantTestSupport.session()
            ) as? OpenAIChatProvider
        )
        XCTAssertNotEqual(again.sessionID, id, "a second provider for a new conversation starts its own")
    }

    func testTheRewritePathSendsTheHeaderAndStartsItsOwnConversation() throws {
        let settings = AssistantSettings(providerID: AssistantProviderID.openCodeGo)
        let first = try XCTUnwrap(
            try AssistantProviderCatalogue.makeProvider(
                settings: settings,
                apiKey: syntheticKey,
                session: AssistantTestSupport.session(),
                forRewrite: true
            ) as? OpenAIChatProvider
        )
        let second = try XCTUnwrap(
            try AssistantProviderCatalogue.makeProvider(
                settings: settings,
                apiKey: syntheticKey,
                session: AssistantTestSupport.session(),
                forRewrite: true
            ) as? OpenAIChatProvider
        )
        let request = try first.makeRequest(messages: [.user("hi")], tools: [], model: "m")
        XCTAssertEqual(sessionID(in: request), first.sessionID)
        XCTAssertNotEqual(first.sessionID, second.sessionID, "a rewrite builds a provider per request")
    }

    // MARK: - What must stay true

    func testTheGoProviderStillRefusesWhatItRefusedBefore() throws {
        let cleartext = OpenAIChatProvider(
            baseURL: URL(string: "http://example.com/v1")!,
            apiKey: syntheticKey,
            sessionHeader: .openCodeGo,
            session: AssistantTestSupport.session()
        )
        XCTAssertThrowsError(
            try cleartext.makeRequest(messages: [.user("hi")], tools: [], model: "m")
        ) { error in
            guard let rejection = error as? EndpointPolicy.Rejection,
                  case .cleartextHost(let host) = rejection
            else {
                return XCTFail("expected cleartextHost, got \(error)")
            }
            XCTAssertEqual(host, "example.com")
        }

        let emptyModel = OpenAIChatProvider(
            baseURL: URL(string: "https://opencode.ai/inference/go/openai/v1")!,
            apiKey: syntheticKey,
            sessionHeader: .openCodeGo,
            session: AssistantTestSupport.session()
        )
        XCTAssertThrowsError(
            try emptyModel.makeRequest(messages: [.user("hi")], tools: [], model: "  ")
        ) { error in
            guard case ProviderError.unavailable = error else {
                return XCTFail("expected unavailable, got \(error)")
            }
        }
    }

    func testTheSessionIDIsNeverWrittenIntoTheRecord() throws {
        let settings = AssistantSettings(
            providerID: AssistantProviderID.openCodeGo,
            model: "deepseek-v4.1-flash"
        )
        let provider = try XCTUnwrap(
            try AssistantProviderCatalogue.makeProvider(
                settings: settings,
                apiKey: syntheticKey,
                session: AssistantTestSupport.session()
            ) as? OpenAIChatProvider
        )
        let id = try XCTUnwrap(provider.sessionID)
        let encoded = try JSONEncoder().encode(settings)
        let record = String(decoding: encoded, as: UTF8.self)
        XCTAssertFalse(record.contains(id), "the session id is not a setting")
        XCTAssertFalse(record.contains("ses_"), "nothing about a session is written to the file")
    }
}
