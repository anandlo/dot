import Foundation
import Network
import XCTest

@testable import DotCore

/// How much of a service's answer Dot will hold.
///
/// `URLSession.data(for:)` buffers the whole body before the caller sees it, so
/// an endpoint that answers with a gigabyte is a gigabyte of memory. The
/// transport reads with a ceiling instead.
final class HTTPTransportTests: XCTestCase {
    private func request(_ port: Int) -> URLRequest {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/audio/transcriptions")!)
        request.httpMethod = "POST"
        request.httpBody = Data("audio".utf8)
        return request
    }

    /// Waits, for a bounded time, until the stub has received `count` requests.
    private func waitForRequests(_ server: HangingStubServer, _ count: Int) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while server.requests < count, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return server.requests >= count
    }

    func testAnAnswerInsideTheLimitIsRead() async throws {
        let server = try StubServer(responses: [
            .init(status: 200, json: #"{"text": "hello"}"#),
        ])
        let answer = try await HTTPTransport.send(
            request(server.port),
            session: OpenAICompatibleProvider.makeSession(),
            limit: 1_024
        )
        XCTAssertEqual(String(decoding: answer.data, as: UTF8.self), #"{"text": "hello"}"#)
        XCTAssertEqual((answer.response as? HTTPURLResponse)?.statusCode, 200)
    }

    func testAnAnswerPastTheLimitIsRefusedInsteadOfBuffered() async throws {
        // Half a megabyte of markup, declared on the wire: exactly the shape a
        // proxy or a captive portal answers a POST with.
        let page = Data(String(repeating: "<html>not a transcript</html>", count: 20_000).utf8)
        let server = try StubServer(responses: [
            .init(status: 200, body: page, contentType: "text/html"),
        ])
        do {
            _ = try await HTTPTransport.send(
                request(server.port),
                session: OpenAICompatibleProvider.makeSession(),
                limit: 1_024
            )
            XCTFail("an oversized answer was accepted")
        } catch ProviderError.invalidResponse(let detail) {
            XCTAssertEqual(detail, ProviderErrorText.oversizedAnswer)
        }
    }

    func testAProviderRefusesAnOversizedErrorPage() async throws {
        // Past the ceiling the transport itself enforces, not the small one the
        // tests above use.
        let page = Data(String(repeating: "<html>blocked by a proxy</html>", count: 200_000).utf8)
        XCTAssertGreaterThan(page.count, HTTPTransport.maximumResponseBytes)
        let server = try StubServer(responses: [
            .init(status: 500, body: page, contentType: "text/html"),
        ])
        let provider = OpenAICompatibleProvider(
            baseURL: URL(string: "http://127.0.0.1:\(server.port)/v1")!,
            apiKey: "test-key"
        )
        do {
            _ = try await provider.transcribe(
                wav: WAVWriter.encode(samples: [0, 10]),
                model: nil,
                language: nil
            )
            XCTFail("the oversized answer was accepted")
        } catch ProviderError.invalidResponse(let detail) {
            XCTAssertEqual(detail, ProviderErrorText.oversizedAnswer)
        }
    }

    // MARK: - Cancellation

    func testCancellingWhileWaitingForTheResponseIsNotATransportError() async throws {
        let server = try HangingStubServer(.noAnswer)
        defer { server.stop() }
        let urlRequest = request(server.port)
        let session = OpenAICompatibleProvider.makeSession()
        let task = Task {
            try await HTTPTransport.send(urlRequest, session: session, limit: 1_024)
        }
        let arrived = await waitForRequests(server, 1)
        XCTAssertTrue(arrived, "the request never reached the stub")
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("a cancelled request returned an answer")
        } catch is CancellationError {
            // Expected: the take was cancelled, not the service unreachable.
        } catch {
            XCTFail("cancellation became \(error)")
        }
    }

    func testCancellingWhileTheBodyIsArrivingIsNotATransportError() async throws {
        let server = try HangingStubServer(.partialBody)
        defer { server.stop() }
        let urlRequest = request(server.port)
        let session = OpenAICompatibleProvider.makeSession()
        let task = Task {
            try await HTTPTransport.send(urlRequest, session: session, limit: 4_096)
        }
        let arrived = await waitForRequests(server, 1)
        XCTAssertTrue(arrived, "the request never reached the stub")
        // The stub has written the head and part of a body it never finishes.
        // The pause is the reader's moment to take the head and park on the
        // bytes that are missing; on loopback that is well under a millisecond.
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("a cancelled request returned an answer")
        } catch is CancellationError {
            // Expected: the body read stopped because the task was cancelled.
        } catch {
            XCTFail("cancellation became \(error)")
        }
    }

    func testASessionCancelledRequestIsATransportError() async throws {
        let server = try HangingStubServer(.noAnswer)
        defer { server.stop() }
        let urlRequest = request(server.port)
        let session = OpenAICompatibleProvider.makeSession()
        let task = Task {
            try await HTTPTransport.send(urlRequest, session: session, limit: 1_024)
        }
        let arrived = await waitForRequests(server, 1)
        XCTAssertTrue(arrived, "the request never reached the stub")
        // The caller's task is still running. The session aborts the request on
        // its own, which is a transport failure: the caller never asked the
        // take to stop.
        session.invalidateAndCancel()
        do {
            _ = try await task.value
            XCTFail("a request cancelled by its session returned an answer")
        } catch is CancellationError {
            XCTFail("the session's cancellation became the caller's cancellation")
        } catch ProviderError.transport {
            // Expected.
        } catch {
            XCTFail("the session's cancellation became \(error)")
        }
    }
}

/// A loopback server that reads the request and then stops talking.
///
/// The transport is what is under test here, so the server's job is silence: a
/// request still waiting for the response head, or for the rest of a declared
/// body, is exactly the request a cancelled task has to give up without calling
/// it a service that could not be reached.
private final class HangingStubServer: @unchecked Sendable {
    /// How much of an answer the server withholds.
    enum Silence {
        /// Read the request and send nothing back.
        case noAnswer
        /// Send a head and part of a longer body, then stop.
        case partialBody
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "dot.stub.hanging")
    private let silence: Silence
    private let lock = NSLock()
    private var received = 0
    private var open: [NWConnection] = []

    /// The port the server listens on.
    private(set) var port: Int = 0

    init(_ silence: Silence) throws {
        self.silence = silence
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters, on: .any)

        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
            if case .failed = state { ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.start(queue: queue)
        XCTAssertEqual(ready.wait(timeout: .now() + 5), .success, "the hanging server did not start")
        port = Int(listener.port?.rawValue ?? 0)
    }

    deinit {
        stop()
    }

    /// How many requests have arrived so far.
    var requests: Int {
        lock.lock()
        defer { lock.unlock() }
        return received
    }

    /// Stops listening and closes every connection that is still open.
    func stop() {
        lock.lock()
        let connections = open
        open.removeAll()
        lock.unlock()
        listener.cancel()
        for connection in connections { connection.cancel() }
    }

    private func handle(_ connection: NWConnection) {
        lock.lock()
        open.append(connection)
        lock.unlock()
        connection.start(queue: queue)
        read(connection, buffer: Data())
    }

    private func read(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var accumulated = buffer
            if let data { accumulated.append(data) }
            guard accumulated.range(of: Data("\r\n\r\n".utf8)) != nil else {
                if isComplete || error != nil {
                    connection.cancel()
                } else {
                    self.read(connection, buffer: accumulated)
                }
                return
            }
            self.lock.lock()
            self.received += 1
            self.lock.unlock()
            guard case .partialBody = self.silence else { return }
            var head = "HTTP/1.1 200 OK\r\n"
            head += "Content-Type: application/json\r\n"
            // More than is ever sent, so the reader waits for the remainder.
            head += "Content-Length: 1024\r\n"
            head += "Connection: close\r\n\r\n"
            head += #"{"text": "#
            connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
        }
    }
}
