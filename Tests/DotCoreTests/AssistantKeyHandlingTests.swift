import XCTest

@testable import DotCore

/// A key reaches the service and nowhere else.
///
/// The key travels in one header, never in a body, a path or a record that is
/// written to disk. The log's redaction is tested through the mechanism the
/// assistant actually relies on: a key resolved through ``CredentialCache`` is
/// registered as a secret the moment it is read.
final class AssistantKeyHandlingTests: XCTestCase {
    private let secret = "sk-live-0123456789abcdef"

    private func sseOK() -> StubServer.Response {
        StubServer.Response(
            status: 200,
            body: AssistantTestSupport.sse([
                #"{"choices":[{"delta":{"content":"ok"},"finish_reason":"stop"}]}"#,
                "[DONE]",
            ]),
            contentType: "text/event-stream"
        )
    }

    func testOpenAIKeepsTheKeyInTheHeaderOnly() async throws {
        let server = try StubServer(responses: [sseOK()])
        let provider = OpenAIChatProvider(
            baseURL: try AssistantTestSupport.loopbackURL(server),
            apiKey: secret,
            session: AssistantTestSupport.session()
        )
        _ = try await AssistantTestSupport.events(
            provider.stream(messages: [.user("hi")], tools: [], model: "m")
        )

        let received = try XCTUnwrap(server.requests.first)
        XCTAssertEqual(received.header("Authorization"), "Bearer \(secret)")
        XCTAssertFalse(String(decoding: received.body, as: UTF8.self).contains(secret))
        XCTAssertFalse(received.path.contains(secret))
        XCTAssertFalse(received.query.contains(secret))
    }

    func testAnthropicKeepsTheKeyInItsOwnHeaderOnly() async throws {
        let server = try StubServer(responses: [
            StubServer.Response(
                status: 200,
                body: AssistantTestSupport.namedSSE([
                    (name: "message_stop", data: #"{"type":"message_stop"}"#),
                ]),
                contentType: "text/event-stream"
            )
        ])
        let provider = AnthropicChatProvider(
            baseURL: try AssistantTestSupport.loopbackURL(server, path: ""),
            apiKey: secret,
            session: AssistantTestSupport.session()
        )
        _ = try await AssistantTestSupport.events(
            provider.stream(messages: [.user("hi")], tools: [], model: "m")
        )

        let received = try XCTUnwrap(server.requests.first)
        XCTAssertEqual(received.header("x-api-key"), secret)
        XCTAssertNil(received.header("Authorization"))
        XCTAssertFalse(String(decoding: received.body, as: UTF8.self).contains(secret))
    }

    func testAKeyResolvedThroughTheCacheIsRedactedByTheLog() {
        let key = secret
        let cache = CredentialCache(reader: { _ in .key(key) }, logsReads: false)
        XCTAssertEqual(cache.key(for: "openai"), key)

        let line = "Authorization: Bearer \(key)"
        XCTAssertEqual(Log.shared.redact(line), "Authorization: Bearer ***")
        XCTAssertFalse(Log.shared.redact("the key \(key) was used").contains(key))
    }

    func testTheAssistantRecordCannotHoldAKey() throws {
        var settings = AssistantSettings.default
        settings.providerID = "openai"
        settings.model = "test-model"
        settings.baseURL = "https://api.openai.com/v1"
        let json = String(decoding: try JSONEncoder().encode(settings), as: UTF8.self).lowercased()

        // The same words SecurityTests refuses in the configuration file.
        for word in ["apikey", "api_key", "secret", "token", "password", "credential"] {
            XCTAssertFalse(json.contains(word), "the assistant record names \(word)")
        }
        XCTAssertFalse(json.contains(secret.lowercased()))
    }
}
