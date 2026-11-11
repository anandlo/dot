import Foundation
import XCTest

@testable import DotCore

/// The pieces every assistant test needs.
enum AssistantTestSupport {
    /// A session that fails fast: a wrong address should be a fast test, not a
    /// two minute one.
    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 10
        return URLSession(configuration: configuration)
    }

    /// The loopback address of a stub server.
    static func loopbackURL(_ server: StubServer, path: String = "/v1") throws -> URL {
        try EndpointPolicy.url(from: "http://127.0.0.1:\(server.port)\(path)")
    }

    /// An SSE body with one `data:` payload per entry.
    static func sse(_ payloads: [String]) -> Data {
        Data(payloads.map { "data: \($0)\n\n" }.joined().utf8)
    }

    /// An SSE body with named events, as Anthropic sends them.
    static func namedSSE(_ events: [(name: String?, data: String)]) -> Data {
        let text = events.map { event -> String in
            var block = ""
            if let name = event.name { block += "event: \(name)\n" }
            block += "data: \(event.data)\n\n"
            return block
        }.joined()
        return Data(text.utf8)
    }

    /// Every event of a stream, in order.
    static func events(_ stream: AsyncThrowingStream<ChatEvent, Error>) async throws -> [ChatEvent] {
        var collected: [ChatEvent] = []
        for try await event in stream {
            collected.append(event)
        }
        return collected
    }

    /// The JSON object a request body holds.
    static func json(_ data: Data?) -> [String: Any] {
        guard let data,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object
    }

    /// The milliseconds between two instants.
    static func milliseconds(from start: ContinuousClock.Instant, to end: ContinuousClock.Instant) -> Double {
        let duration = end - start
        let components = duration.components
        return Double(components.seconds) * 1000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }
}
